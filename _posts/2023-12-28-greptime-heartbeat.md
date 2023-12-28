---
title: GreptimeDB Heartbeat机制详解
date: 2023-12-28 16:14
category:
    - GreptimeDB
tag:
    - WIP 🚧
    - GreptimeDB
    - Heartbeat
---

![](https://raw.githubusercontent.com/J0HN50N133/tuchuang/main/Pasted%20image%2020231215222045.png)
本文将讲解`greptimedb`内部的heartbeat机制。首先看看官网Developer guide的介绍：

> Heartbeat Task is used to send heartbeat to the Metasrv. The heartbeat plays a crucial role in the distributed architecture of GreptimeDB and serves as a basic communication channel for distributed coordination. The upstream heartbeat messages contain important information such as the workload of a Region. If the Metasrv has made scheduling(such as Region migration) decisions, it will send instructions to the Datanode via downstream heartbeat messages.

## Overview
可以看到在`greptimedb`中`Heartbeat`分两个方向`upstream`和`downstream`，并且`Datanode`和`Frontend`都会向`Meta Server`发送心跳。`upstream`是`datanode`上报`region`信息到`meta srv`，`downstream`方向是`meta srv`主动向`datanode`发起调度。
## Datanode的Heartbeat
主要逻辑位于：`datanode/src/heartbeat.rs`里。核心是`HeartbeatTask`。在`Datanode`启动的时候，`HeartbeatTask`随之`start`，并且`Datanode`会传入其`region_event_receiver`和`leases_notifier`给`HeartbeatTask`。`region_event_receiver`接收`RegionServerEvent`，也就是`region`的`Registered`和`Deregistered`两个事件，因为`Heartbeat`上报的是`RegionStat`，故`Region`发生了`Registered`和`Deregistered`时，自然需要做出对应的逻辑调整。
<!-- `leases_notifier`不知道是干啥的。//TODO::  -->

### HeartbeatTask的创建
逻辑位于`HeartbeatTask::try_new`中。
首先是创建了一个`region_alive_keeper`。这个东西非常重要，首先看看源码里的文档是怎么说的：

```
/// [RegionAliveKeeper] manages all [CountdownTaskHandle]s.
///
/// [RegionAliveKeeper] starts a [CountdownTask] for each region. When the deadline is reached,
/// the status of region be set to "readonly", ensures there is no side-effect in the entity system.
///
/// The deadline is controlled by the meta server. Datanode will send its opened regions info to meta sever
/// via heartbeat. If the meta server decides some region could be resided in this Datanode,
/// it will renew the lease of region, a deadline of [CountdownTask] will be reset.
```

核心意思就是说：`region_alive_keeper`为每个`region`维护了一个倒计时任务，一旦这个任务被执行，`region`就变成`readonly`状态（不知道和memtable的frozen有没有关系）。`heartbeat`时会上报所有`open`的`region`的`RegionStat`，如果`meta srv`认为这个`region`能继续存活，就会刷新这个`region`的`lease`，也就是重置倒计时。`RegionAliveKeeper`有一个`epoch`，指的是该`RegionAliveKeeper`创建的时间，刷新`region`的`lease`的时候会以这个`epoch`为基准进行计算(`RegionAliveKeeper`作为`HeartbeatResponseHandler`的行为)；发送`HearbeatRequest`的时候也以`epoch`作为基准，计算当前时间和`epoch`的偏移量`duration_since_epoch`并放在`Request`里上报。
然后是创建一个`resp_handler_executor`，这里`resp_handler_executor`的核心是一个`Arc<dyn HeartbeatResponseHandler`的`vec`，包了一层抽象叫`HandlerGroupExecutor`，接收到`resp`以后就遍历执行这组`HeartbeatResponseHandler`。
创建`HeartbeatTask`阶段比较trivial的解析`options`之类的逻辑就不再赘述了，不过值得注意的是`HeartbeatTask`还取了创建任务的时间并记录在`node_epoch`字段里。

### HeartbeatTask的启动
创建完以后就进行`HeartbeatTask`的启动了。启动的核心逻辑如下：
首先判断一下当前task是否已经启动过了，避免重复启动。
然后取一大堆`interval`,`node_id`,`node_epoch`,`addr`,**`meta_client`** 之类的数据,并创建了一个逻辑上可以称为`outgoing`的管道。用`outgoing_tx`创建了一个`HeartbeatMailbox`。用前面获取的数据创建了一个和`meta_srv`之间的`heartbeat stream`，并且获取一个能通过该`stream`发送`Heartbeat`的`HeartbeatSender`称之为`tx`,而创建`stream时做了什么这里按下不表，后面再说。
取得了`tx`以后，启动了`region_alive_keeper`。
然后创建了一个死循环，循环的逻辑如下：
1. 判断当前任务是否被关闭了，是就退出
2. 否则，`tokio::select`三件事：
	1. 要么从`outgoing`这个channel中收到一个`message`，把这个`MailboxMessage`encode成一个`HeartbeatRequest`
		1. 于是有一个这样的数据流`mailbox->tx->meta srv`
		2. `mailbox`的数据来源
			1. 对`IncomingMessage`（也就是`Meta srv`对`Datanode`发出的`Instruction`）对应的响应(`OutgoingMessage`=`MessageMeta`+`InstructionReply`)
	2. 要么睡够了`interval`这么长的时间(第一次进循环时不睡，直接进这个事件)，收集所有`opened_region`的`region_stat`，构造`HeartbeatRequest`
	3. 要么收到了`quit_signal`，构造一个dummy heartbeat request，通过后续发送重新建立heartbeat stream。
3. 通过`tx`(HeartbeatSender)发送上一步构造的`HeartbeatRequst`,如果发送出现错误，尝试重新建立`heartbeat stream`
### HeartbeatStream
上文提到了在启动`HeartbeatTask`的时候会通过`create_streams`这个函数创建一个`heartbeat stream`，通过`heartbeat stream`进行`meta srv`和`datanode`之间心跳包的双向通讯。这个`heartbeat stream`的`tx`端如何使用上文已经说过了，而`create_streams`中则创建了`datanode`处理`rx`端的死循环，循环就是不断处理来自`meta srv`的包，数据包可能是`mailbox incoming message`，也可能是普通的`region_lease`刷新`message`，处理时会对这些数据包做些信息收集工作(打info log或者收集到metric里)，然后就是让前文的`handler_executor`处理这些包，最后如果上文的`lease_notifier`存在，那就`notify`一下。
上面都是正确运行时的循环逻辑，如果从`rx`端接收数据包的时候发生错误了，那循环就退出了，并且向`quit_signal`中发送信号，表明当前流被断开。
上面是`rx`端处理的逻辑。通过前面的综合分析，可以得到下面的图，`datanode`和`MetaSrv`可以双向通讯，并非简单的C/S模式：


![](https://raw.githubusercontent.com/J0HN50N133/tuchuang/main/HeartbeatMailboxOfDatanode.excalidraw.svg)


而建立stream的逻辑实际上在`meta_client.heartbeat()`中，`meta_client.heartbeat()`转到了`heartbeat_client().heartbeat()`里，这里可以参考[[MetaClient]]。
`heartbeat_client().hearbeat()`第一步是`ask_leader`，其流程是获取当前的`leadership_group`的所有`peers`后`shuffle`之，再遍历一趟，向每个`peer`发送`AskLeaderRequest`，得到`leader`以后，向`leadership_group`写入`leader`信息。
第二步是真正的`inner.heartbeat()`，逻辑如下：
1. 构造一个连接到`leader`的`client`
2. 构造用于发送请求的`mpsc::channel::<HeartbeatRequest>(128)`(这应该是`tonic`这个框架里的某种idiom)
```rust
let (sender, receiver) = mpsc::channel::<HeartbeatRequest>(128);
sender.send(handshake).await.map_err(|e| {...});
let receiver = ReceiverStream::new(receiver);
let mut stream = leader
	.heartbeat(receiver)
	.await
// 后续发送请求只要往sender里send就行了，不用关心别的
```
3. 构造包含当前节点`node_id`和`role`端的`RequestHeader`
4. 构造一个起握手作用的`HeartbeatRequest`，并用`sender`发送之
5. 构造和leader之间的`stream`
6. 获取上面的请求响应，错误了就处理错误
7. 包装上面管道的`sender`为请求`sender`，包装`stream`为`receiver`

## Meta Server对HeartbeatRequest的处理
### 纵览逻辑
首先找到最关键的`trait`,`HeartbeatHandler`。
```rust
#[async_trait::async_trait]
pub trait HeartbeatHandler: Send + Sync {
    fn is_acceptable(&self, role: Role) -> bool;

    fn name(&self) -> &'static str {
        let type_name = std::any::type_name::<Self>();
        // short name
        type_name.split("::").last().unwrap_or(type_name)
    }

    async fn handle(
        &self,
        req: &HeartbeatRequest,
        ctx: &mut Context,
        acc: &mut HeartbeatAccumulator,
    ) -> Result<HandleControl>;
}

```
看到这里就能猜到大概的结构就是有一个总的`handler`，然后根据不同`Heartbeat`的类型将其分发给具体的`handler`（策略模式） 。
总的`handler`在`impl heartbeat_server::Heartbeat for MetaSrv`里，`heartbeat_server::Heartbeta`这个`trait`定义核心逻辑非常简单：
```rust
pub trait Heartbeat {
	type HeartbeatStream;
	fn heartbeat(&self, tonic::Request<tonic::Streaming<...>>)->...;
	fn ask_leader(&self, request: tonic::Request<AskLeaderRequest>)->...;
}
```

`MetaSrv`的`heartbeat`也非常简单，核心是一个循环，不断得从`stream`里取出`request`，进行以下操作：
1. 解析`request`，首先`match`看看是不是一个合法的`request`，不然进错误处理(`Err`分支)
2. 取出`header`，没有`header`就报错
3. 如果`pusher_key`是`None`
	1. 取出`node_id`，注意，`datanode`和`frontend`的`heartbeat`都是走这个处理函数的，`datanode`的`node_id`是由`datanode`传递过来的`member_id`，虽然`datanode`传过来的`id`=`(cluster_id, member_id)`，但这里只用了`member_id`。而`frontend`则是一个`metasrv`内部的自增`AtomicU64`
	2. 取出`role`，也就是请求发送方到底是`datanode`还是`frontend`
	3. `node_id`和`role`拼成key，然后向`handle_group`里用这个`key`注册一个返回请求的`pusher`，`handle_group`里有一个从`key`到`pusher`的`map`，`pusher`用于主动向下游发送信息(`MailboxMessage`)，所以可以猜测，发送`MailboxMessage`的时候，收信方是以`key`来标识的，也就是`HeartbeatMailbox::send`里的`pusher_id`。
	4. 将`pusher_key`设为`Some(key)`，这里`pusher_key`不为`None`以后就不用再进这个分支，因为`heartbeat`时`Client`和`Server`之间是长连接的`Stream`，后面`Client`的key也不会变化，第一次`handshake`完了以后，就不需要重新构建链接，也就不需要再注册`key`及其对应的`Pusher`。(`Frontend`因为是无状态的，猜测其`node_id`会由第一次`handshake`从`MetaSrv`处分配后在`Response`里获得)。
		于是整体数据的流动可以看成这样
        ![](https://raw.githubusercontent.com/J0HN50N133/tuchuang/main/HeartbeatDataflow.svg)
4. 使用HandlerGroup去handle这个request，并得到result
	1. 逻辑上`HandlerGroup`是一个`HeartbeatHandler`的`Vec`，不过有点小细节的是，实际用的是`NameCachedHandler`这个包装，其作用是缓存了`HeartbeatHandler.name()`的结果，避免每次都对这个常量去求值(这里`name`等于实际的struct type name)
	2. `HandlerGroup::handle`遍历所有`handler`，一边遍历一边把中间结果存到`HeartbeatAccumulator`中，每个`handler`返回`Continue`或者`Done`，返回`Done`说明这个请求已经处理完了，直接跳出循环，然后把`accmulator`的内容提取并返回
	3. `HandlerGroup`里还有`pushers`
5. 根据result判断当前stream连接的还是不是leader,如果已经不是leader了，主动断开当前的stream
	1. 断开stream的时候将第3步注册的pusher给`unregister`掉

### 每个handler的逻辑

#### CollectStatsHandler
- 职责：负责收集`HeartbeatRequest`中的`stat`到`accumulator.stat`中。
- 接受请求来源：只接受来自`datanode`的`Heartbeat`，并且不处理`MailboxMessage`（`MailboxMessage`不会有stat）。
- 实现逻辑：
	- 如果请求是`MailboxMessage`，直接返回`Continue`。
	- 尝试从`Request`中提取出`Stat`，成功提取了就将`stat`插入`accumulator.stat`，失败了打一条警告信息
	- 返回`Continue`

#### CheckLeaderHandler
- 职责：判断当前`MetaSrv`是否仍是`Leader`
- 接受请求来源：只接受来自`datanode`的`Heartbeat`。
- 实现逻辑：
	- 如果当前`context`里没有`election`模块(没有可能是单节点模式)，直接返回`Continue`
	- 用上面获取到的`election`模块判断当前`metasrv`是否是`leader`，是`leader`可以直接返回`Continue`
	- 不是`leader`就在`Response`的`header`里写入错误信息`Error::is_not_leader()`
	- 返回`Done`，因为当前节点不是`leader`的话，后面的`handler`也没有必要再继续做了

#### KeepLeaseHandler
- 职责：维护每个节点上次续租的时间，也就是`node`到`lease`的`KV`对
- 接受请求来源：`datanode`
- 实现逻辑：
	- 取出`Request`的`header`和`peer`(请求来自谁)，没有直接返回
	- 拼出`lease_key`:`(cluster_id,node_id)`
	- 拼出`lease_value`：当前的时间戳（语义为上次活动时间）和`peer`的地址
	- 把上面的`key`和`value`转成字节数组(`Vec<u8>`)，写入存储元数据的`KV`库。这里写入的是`ResettableKvBackend`，没有进行持久化
	- 返回`Continue`

#### RegionLeaseHandler
- 核心逻辑
	- 取出`stat`的所有`regions`及其所在的`cluster_id`和`datanode_id`
		- 刷新每个`cluster_id`,`datanode_id`和`region_id`构成的三元组对应的`lease`；返回不存在的`region`以及成功刷新的`region`有哪些(注意`region_id`和`role`才构成一个完整的`region`描述符)
	- 成功刷新`lease`的`regions`集合转成`GrantedRegion`的`vector`

#### PersistStatsHandler
- 接受请求来源：`datanode`
- 具体实现逻辑：
	- 取出`accumulator`里的`stat`，没有就直接返回
	- 取`stat`的`stat_key`(同样是`(cluster_id, node_id)`)
		- `PersistStatsHandler`内有一个`StatKey->EpochStats`的`DashMap`，称为`stats_cache`
		- `EpochStats`=Optional Epoch + Vector of `Stat`
	- 取出`stat_cache`里记录的`epoch_stat`，没有就插个默认的
	- 判断是否需要刷新`epoch`
		- 如果`epoch_stat`里存在`epoch`,如果`current_stat`传过来的`node_epoch`更大就更新，并且清空之前记录的所有`stat`(因为这意味着`node`可能重新deploy了，`node_epoch`发生了改变);`node_epoch`更小就是接收到了过期的`heartbeat`，那么忽略，并警告；如果`node_epoch`和`epoch`相等，则是正常的
		- 如果`epoch_stat`里不存在`epoch`，毫无疑问，直接设置`current_stat`里传过来的`node_epoch`作为`epoch`
	- 向`epoch_stat`中插入`current_stat`
	- 如果之前判断不需要刷新`epoch`，那么只需要判断`epoch_stats`里记录的`stat`数量是否小于阈值`MAX_CACHED_STATS_PER_KEY`，小于就返回`Continue`
	- 否则，需要持久化`epoch_stats`了，把`epoch_stats`的所有`stats`拎出来(`drain_all`)然后写到`in_memory`的`KV`里
- 结论：
	- `stats`做了一个多阶段的`Cache`，首先在`Hadler`里按`(cluster_id,node_id)`作为`key`，维护了一个记录对应的`stats`的局部`cache`，用`epoch`来判断当前的`stats`是否仍然合法；写满了就写到全局的`in_memory`键值存储里，缓解全局`in_memory`存储的压力
 
## Datanode对HeartbeatResponse的处理
