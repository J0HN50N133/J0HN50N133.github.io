FROM archlinux:base-devel
RUN pacman -Syu --noconfirm && pacman -S --noconfirm git ruby2.7 ruby-bundler && cp /usr/bin/ruby-2.7 /usr/bin/ruby && gem install bundler -v 2.4.22
VOLUME [ "/data" ]
WORKDIR "/data"
EXPOSE 4000 35729
ENTRYPOINT [ "./entrypoint.sh" ]