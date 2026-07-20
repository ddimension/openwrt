/*
 * EIN EINZIGES PT_LOAD-Segment — Code, komprimierter Kernel und DTB zusammen.
 *
 * Begruendung:
 *   - Das eigene Segment ist nachweislich lesbar (Code laeuft, .rodata, Stack,
 *     .bss). Jeder Zugriff auf ein SEPARAT geladenes Payload-Segment starb
 *     dagegen, egal bei welcher Adresse und egal ob MMU an oder aus.
 *   - MikroTiks eigener Loader hat ebenfalls genau ein PT_LOAD.
 *   - Beim spaeteren Flash-Boot liest RouterBOOT eine einzelne yaffs-Datei. Ein
 *     Loader, der alles mitbringt, verhaelt sich dort identisch zum Netboot —
 *     wir testen also schon jetzt die spaetere Konstellation.
 *
 * Zur Laufzeit wird nur noch GESCHRIEBEN (entpackter Kernel, DTB an ihre
 * Zieladressen) — gelesen wird ausschliesslich aus dem eigenen Segment.
 */
ENTRY(_start)
PHDRS {
	all PT_LOAD FLAGS(7);	/* rwx, wie MikroTiks Loader */
}
SECTIONS {
	. = 0x01100000;

	.text : { *(.text.start) *(.text*) } :all
	.rodata : { *(.rodata*) } :all
	.data : { *(.data*) } :all

	. = ALIGN(16);
	.payload.kernel : {
		_payload_start = .;
		*(.payload.kernel)
		_payload_end = .;
	} :all

	. = ALIGN(16);
	.payload.dtb : {
		_dtb_start = .;
		*(.payload.dtb)
		_dtb_end = .;
	} :all

	.bss : {
		. = ALIGN(8);
		__bss_start = .;
		*(.bss*)
		*(COMMON)
		. = ALIGN(8);
		__bss_end = .;
	} :all

	/DISCARD/ : { *(.comment) *(.note*) *(.ARM.attributes) *(.eh_frame*) }
}
