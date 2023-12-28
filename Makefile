build-image:
	docker build -t blog:1.0 -f Dockerfile .
rm-image:
	docker rmi blog:1.0
serve:
	docker run --rm -d -p 127.0.0.1:4000:4000 -p 127.0.0.1:35729:35729 -v ./:/data blog:1.0