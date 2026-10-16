.PHONY: all run install clean

all: build/build.ninja
	meson compile -C build

build/build.ninja:
	meson setup build --prefix $(HOME)/.local

run: all
	./build/intray

install: all
	meson install -C build

clean:
	rm -rf build
