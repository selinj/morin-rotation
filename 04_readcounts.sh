#!/bin/bash

. settings.conf

IN_DIR=$WORK_DIR/00_bams
OUT_DIR=$WORK_DIR/04_readcounts
mkdir -p $OUT_DIR

rm -f jobs.txt && touch jobs.txt

for BAM_FILE in $(ls $IN_DIR/*genome*.bam); do
    OUT_FILE=$OUT_DIR/$(basename $BAM_FILE | sed s/.bam$/.wig/)
    if [[ ! -f $OUT_FILE ]]; then
        echo "$HMMCOPY_DIR/readCounter -c 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,X,Y $BAM_FILE > $OUT_FILE" >> jobs.txt
    else
        echo "Output file $OUT_FILE already exists" >&2
    fi
done

exit 0
if [[ $(wc -l jobs.txt) -gt 0 ]]; then
    mqsub --file jobs.txt --chdir qsub-logs --name readCounter --qsub "-l h_vmem=1G -l mem_token=1G -l mem_free=1G"
fi