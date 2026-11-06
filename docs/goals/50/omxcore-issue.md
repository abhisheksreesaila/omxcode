# Draft issue for omxcore (not filed): declare pthread_create as Flare does

Mojo allows one signature per external symbol per binary. omxcore's jobs declare `pthread_create` as
`(Pointer[Int] thread, Pointer[UInt8] attr, def(Int) abi("C") -> Int start, Int arg)`; Flare v0.12
(vendor/flare/runtime/_thread.mojo) declares it as `(Pointer[UInt64], Pointer[UInt8], def(Pointer[UInt8]) thin ->
Pointer[UInt8], Pointer[UInt8])`. A program that uses engine jobs and Flare (an HTTPS fetch, mojoui.serve) fails with
"existing function with conflicting signature". mojoui moved to Flare's form (mojoui/libc.mojo, goal 50 D-4782);
the ask: omxcore's job threads take Flare's form too (entry `def(Pointer[UInt8, MutUntrackedOrigin]) -> Pointer[UInt8,
MutUntrackedOrigin]`, the argument an address), and the other libc symbols both declare (read, close, poll…) follow
mojoui/libc.mojo's types. Found 2026-11-04.
