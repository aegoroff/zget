build ver="0.1.3":
  zig build  -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl --summary all -Dcpu=haswell -Dversion={{ver}}

test ver="0.1.3":
  zig build test -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl --summary all -Dcpu=haswell -Dversion={{ver}}
