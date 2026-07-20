/* Eingebettete Nutzlast: LZMA-komprimierter Kernel + DTB, liegen im selben PT_LOAD wie der Code (siehe loader.lds). */
	.section .payload.kernel, "a"
	.incbin "kernel.img.lzma"

	.section .payload.dtb, "a"
	.incbin "chateau.dtb"
