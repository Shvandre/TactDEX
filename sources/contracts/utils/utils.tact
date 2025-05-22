asm fun emptyAddress(): Address { b{00} PUSHSLICE }

asm fun sliceWithOneZeroBit(): Slice {
    b{0} PUSHSLICE
}

asm fun muldiv(x: Int, y: Int, z: Int): Int { MULDIV }

// CALLCC resets c0 and c1 to default quit-cont (extraordinary continuation),
// so after implicit RET we will call quit-cont
asm fun exit() { <{ }> PUSHCONT CALLCC }
