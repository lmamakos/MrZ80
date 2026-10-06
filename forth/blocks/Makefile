all: forth.blk

%.blk : %.fth
	@awk 'length > 64 { \
	        printf "%s:%d: line is %d bytes (max 64)\n", FILENAME, FNR, length > "/dev/stderr"; \
	        bad=1 } \
	      END { \
	        if (FNR > 16) { \
	          printf "%s: has %d lines (max 16)\n", FILENAME, FNR > "/dev/stderr"; \
	          bad=1 } \
	        if (bad) exit 1 }' $^ \
	  || (echo "$^ does not fit a 16 line x 64 column FORTH block" >&2; exit 1)
	../mkblk.sh $^  > $@ 
	@sz=$$(wc -c < $@); [ $$sz -eq 1024 ] || (echo "Output size $$sz is not exactly 1K" >&2; exit 1)

LINEEDIT = 05-lineedit.blk 06-lineedit.blk 07-lineedit.blk
EDITOR   = 09-editor.blk 10-editor.blk 11-editor.blk 12-editor.blk 13-editor.blk \
           14-editor.blk 15-editor.blk 16-editor.blk 17-editor.blk \
           18-editor.blk 19-editor.blk 20-editor.blk
SEE      = 21-see.blk 22-see.blk 23-see.blk 24-see.blk 

blks=      00-start.blk 01-utils.blk 02-blocks.blk 03-blocks.blk 04-blocks.blk \
           ${LINEEDIT} 08-case.blk  ${EDITOR} ${SEE} 25-mmu.blk 26-fpledtest.blk 27-bench.blk

forth.blk: blank.blk $(blks) Makefile
	cat ${blks} > forth.blk
	( actblk=$$(echo ${blks} | wc -w); \
	  echo Add $$fill empty blocks to initial $$actblk ; \
	  for b in $$(seq $$actblk 127) ; do \
		printf "( %03d ) %1016s" $$b "" >> forth.blk ; \
	  done )
