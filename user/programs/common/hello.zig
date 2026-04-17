// user/hello.zig - Hello world user process

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.print("Hello from GraniteOS's user space, with PID of ");
    io.print_int(sys.getpid());
    io.println("");
    io.println("Exiting...\r\n");

    sys.exit(0);

}
