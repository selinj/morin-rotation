#!/gsc/software/linux-x86_64-centos5/R-3.0.2/bin/Rscript

library(parallel)
library(HMMcopy)
library(flexclust)

source(file="/home/rmccloskey/morin-rotation/settings.conf")

win.size <- as.integer(commandArgs(trailingOnly=T)[1])
if (is.na(win.size)) win.size <- 1000

out.dir <- file.path(WORK_DIR, "05_hmmcopy", win.size)
wig.dir <- file.path(WORK_DIR, "04_readcounts", win.size)
ncpus <- 8

dir.create(out.dir, showWarnings=F)

gc.file <- file.path(wig.dir, sub(".fa$", ".gc.wig", basename(HUMAN_REF)))
map.file <- file.path(wig.dir, sub(".bw$", ".wig", basename(MAPPABILITY_FILE)))

# Get BAM files for each sample.
sample.data <- read.csv(GENOME_METADATA, header=T)
prefix <- paste(sample.data$patient_id, sample.data$gsc_genome_library_id, "*.bam", sep="_")
sample.data$bam.file <- sapply(prefix, function (x) {
    file <- Sys.glob(file.path(WORK_DIR, "00_bams", x))
    if (length(file) == 0) NA else file
})
sample.data <- sample.data[!is.na(sample.data$bam.file),]

sample.data$wig.file <- file.path(wig.dir, sub(".bam$", ".wig", basename(sample.data$bam.file)))
sample.data <- sample.data[file.exists(sample.data$wig.file),]

# merge with tumor purity data
purity.data <- read.table("/home/rmccloskey/morin-rotation/sample_info.dat", header=T)[,c("sample", "purity")]
sample.data <- merge(sample.data, purity.data, by.x=c("sample_id"), by.y=c("sample"))

# Annotate which samples are normal and which are tumor.
# Delete patients with no normal sample.
# TODO: also annotate with pre- and post-biopsy, from the clinical csv.
sample.data$normal <- grepl("(BF|WB)", sample.data$sample_id)
normal.counts <- aggregate(normal~patient_id, sample.data, sum)
normal.counts <- normal.counts[normal.counts$normal == 1,]
sample.data <- merge(sample.data, normal.counts, by=c("patient_id"), suffixes=c("", ".count"))

# Don't redo things.
sample.data$filename.stem <- file.path(out.dir, sample.data$patient_id, sample.data$sample_id)

# Delete patients with only one sample.
bam.counts <- aggregate(bam.file~patient_id, sample.data, length)
bam.counts <- bam.counts[bam.counts$bam.file > 1,]
sample.data <- merge(sample.data, bam.counts, by=c("patient_id"), suffixes=c("", ".count"))

sample.data$patient_id <- factor(sample.data$patient_id, levels=unique(sample.data$patient_id))
. <- sapply(dirname(sample.data$filename.stem), dir.create, showWarnings=F, recursive=T)

. <- Sys.setlocale('LC_ALL','C')

write.output <- function (stem, copy, segments=NULL, params=NULL) {
    pdf(paste0(stem, "_bias.pdf"))
    par(cex.main = 0.7, cex.lab = 0.7, cex.axis = 0.7, mar = c(4, 4, 2, 0.5))
    plotBias(copy, pch = 20, cex = 0.5)
    dev.off()

    pdf(paste0(stem, "_correction.pdf"))
    par(cex.main = 0.7, cex.lab = 0.7, cex.axis = 0.7, mar = c(4, 4, 2, 0.5))
    sapply(c(1:22, "X", "Y"), function (chr) {
        tryCatch(plotCorrection(copy, chr=chr, pch="."), error=identity)
    })
    dev.off()

    if (is.null(segments)) return()
    write.table(segments$seg, file=paste0(stem, "_segments.dat"), col.names=T, row.names=F)

    if (is.null(params)) params <- HMMsegment(copy, getparam=T)
    write.table(params, file=paste0(stem, "_params.dat"), col.names=T, row.names=F)

    rangedDataToSeg(copy, file=paste0(stem, ".seg"))

    pdf(paste0(stem, "_params.pdf"))
    plotParam(segments, params)
    dev.off()

    pdf(paste0(stem, "_segments.pdf"))
    par(cex.main = 0.5, cex.lab = 0.5, cex.axis = 0.5, mar = c(2, 1.5, 0, 0),
        mgp = c(1, 0.5, 0))
    sapply(c(1:22, "X", "Y"), function (chr) {
        cols <- stateCols()
        plotSegments(copy, segments, chr=chr, pch = ".", 
                     ylab = "Tumour Copy Number", 
                     xlab = paste("Chromosome", chr, "Position"))
        sapply(seq(-0.9, 0.9, 0.1), function (y) abline(h=y))
        legend("topleft", c("HOMD", "HETD", "NEUT", "GAIN", "AMPL", "HLAMP"),
               fill = cols, horiz = TRUE, bty = "n", cex = 0.5)
    })
    dev.off()
}

# Apply HMMCopy to each normal/tumor pair.
options(bitmapType="cairo")

sample.data <- sample.data[order(sample.data$patient_id, -sample.data$normal),]
mclapply(levels(sample.data$patient_id), function (p) {
    d <- subset(sample.data, patient_id == p)
    norm.uncorrected.reads <- wigsToRangedData(d[1,"wig.file"], gc.file, map.file)
    norm.corrected.copy <- correctReadcount(norm.uncorrected.reads)
    write.output(d[1, "filename.stem"], norm.corrected.copy)

    sapply(2:nrow(d), function (i) {
        tum.uncorrected.reads <- wigsToRangedData(d[i,"wig.file"], gc.file, map.file)
        tum.corrected.copy <- correctReadcount(tum.uncorrected.reads)
        tum.corrected.copy$copy <- tum.corrected.copy$copy - (2-d[i,"purity"])*norm.corrected.copy$copy

        param <- HMMsegment(tum.corrected.copy, getparam=T)
        param$e <- 0.999999999999999
        param$strength <- 1e+30

        if (!file.exists(paste0(d[i, "filename.stem"], "_default_segments.dat"))) {
            segments <- HMMsegment(tum.corrected.copy, param)
            write.output(paste0(d[i,"filename.stem"], "_default"), tum.corrected.copy, segments=segments, params=param)
            medians <- segments$seg$median
        } else {
            seg <- read.table(paste0(d[i, "filename.stem"], "_default_segments.dat"), header=T)
            medians <- seg$median
        }

        if (!file.exists(paste0(d[i, "filename.stem"], "_kmeans_segments.dat"))) {
            mu <- sort(kmeans(medians, 6)$centers)
            param$mu <- mu
            param$m <- mu
            segments <- HMMsegment(tum.corrected.copy, param)
            write.output(paste0(d[i,"filename.stem"], "_kmeans"), tum.corrected.copy, segments=segments, params=param)
        }

        if (!file.exists(paste0(d[i, "filename.stem"], "_kmedians_segments.dat"))) {
            mu <- sort(kcca(medians, 6, family=kccaFamily("kmedians"))@centers)
            param$mu <- mu
            param$m <- mu
            segments <- HMMsegment(tum.corrected.copy, param)
            write.output(paste0(d[i,"filename.stem"], "_kmedians"), tum.corrected.copy, segments=segments, params=param)
        }
    })
}, mc.cores=ncpus)
