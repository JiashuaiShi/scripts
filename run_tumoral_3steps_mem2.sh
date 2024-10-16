#!/bin/bash

# Run the script in the background:
# nohup bash run_tumoral_3steps.sh > output/20241008_dev09_tumoral/run.log 2>&1 &

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure pipelines fail on the first failure.
set -euo pipefail

# Trap errors and output the line number and command that caused the error.
trap 'echo "Error on line $LINENO: $BASH_COMMAND"; exit 1' ERR

# ----------------------------
# Configuration and Variables
# ----------------------------

# TMP_DIR
export TMP_DIR=/data/lush-dev/shijiashuai/workspace/dev/ctDNA/test/output/tmp

# Generate a timestamp for this run
timestamp=$(date '+%Y%m%d_%H%M%S')

# Output and log directories
output_dir="/data/lush-dev/shijiashuai/workspace/dev/ctDNA/test/output/20241008_dev09_tumoral"
log_dir="$output_dir/logs"
log_file="$log_dir/pipeline_$timestamp.log"

# Sample and file information
sample="tumoral_01"
R1="/data/lush-dev/yinlonghui/ctDNA/E150035817_L01_1218_1.fq.gz"
R2="/data/lush-dev/yinlonghui/ctDNA/E150035817_L01_1218_2.fq.gz"
pl_unit="barcode_001"
pl="MGI"
hg38="/data/lush-dev/shijiashuai/data/bioinfo/index/bwa-liheng/hg38.fa"
hg38_mem2="/data/lush-dev/shijiashuai/data/bioinfo/index/bwa-mem2/hg38.fa"
bwa_threads=40

# Tool paths managed using an associative array
declare -A tools=(
    ["time_cmd"]="/data/lush-dev/shijiashuai/software/time-1.9/time"
    ["java"]="java"
    ["picard"]="/data/lush-dev/shijiashuai/workspace/dev/ctDNA/picard/2.18.29/picard.jar"
    ["fgbio"]="/data/lush-dev/shijiashuai/workspace/dev/ctDNA/fgbio/1.1.0/fgbio-1.1.0.jar"
    ["bwa"]="/data/lush-dev/shijiashuai/workspace/dev/ctDNA/bwa/0.7.17/bwa-0.7.17/bwa"
    ["bwa-mem2"]="/data/lush-dev/shijiashuai/workspace/dev/ctDNA/bwa-mem2/master/bwa-mem2"
)

# ----------------------------
# Function Definitions
# ----------------------------

# Create output and log directories
create_directories() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating output and log directories..." | tee -a "$log_file"
    mkdir -p "$output_dir" "$log_dir"
}

# Check if a tool exists and is executable
check_tool() {
    local tool_name="$1"
    local tool_path="${tools[$tool_name]}"

    if [[ "$tool_name" == "java" ]]; then
        if ! command -v "$tool_path" &> /dev/null; then
            echo "Error: $tool_name not found in PATH." | tee -a "$log_file"
            exit 1
        fi
    elif [[ "$tool_name" == "picard" || "$tool_name" == "fgbio" ]]; then
        if [[ ! -f "$tool_path" ]]; then
            echo "Error: $tool_path not found." | tee -a "$log_file"
            exit 1
        fi
    else
        if [[ ! -x "$tool_path" ]]; then
            echo "Error: $tool_path not found or not executable." | tee -a "$log_file"
            exit 1
        fi
    fi
}

# Check all required tools
check_tools() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking required tools..." | tee -a "$log_file"
    for tool in "${!tools[@]}"; do
        check_tool "$tool"
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] All tools are available." | tee -a "$log_file"
}

# Run a command with logging
run_command() {
    local step_name="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting: $step_name" | tee -a "$log_file"
    "${tools[time_cmd]}" -v "$@" > "$log_dir/${step_name}_$timestamp.log" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed: $step_name" | tee -a "$log_file"
}

# Step 1: Convert FASTQ to uBAM
convert_fastq_to_ubam() {
    run_command "step1_convert_to_uBAM" java -jar "${tools[picard]}" FastqToSam \
        F1="$R1" \
        F2="$R2" \
        OUTPUT="${output_dir}/${sample}.uBAM" \
        READ_GROUP_NAME="$sample" \
        SAMPLE_NAME="$sample" \
        LIBRARY_NAME="$sample" \
        PLATFORM_UNIT="$pl_unit" \
        PLATFORM="$pl" \
        TMP_DIR="$TMP_DIR"
}

# Step 2: Extract UMI tags
extract_umis() {
    run_command "step2_extract_UMIs" java -jar "${tools[fgbio]}" ExtractUmisFromBam \
        --input="${output_dir}/${sample}.uBAM" \
        --output="${output_dir}/${sample}.umi.uBAM" \
        --read-structure="16M1S+T" "16M1S+T" \
        --single-tag=RX \
        --molecular-index-tags=ZA ZB
}

# Step 3: Genome Alignment
align_genome() {
    run_command "step3_first_align" bash -c "
        java -jar ${tools[picard]} SamToFastq I=${output_dir}/${sample}.umi.uBAM F=/dev/stdout INTERLEAVE=true TMP_DIR="$TMP_DIR" |
        ${tools[bwa]} mem -p -t $bwa_threads $hg38 /dev/stdin |
        java -jar ${tools[picard]} MergeBamAlignment \
            UNMAPPED=${output_dir}/${sample}.umi.uBAM \
            ALIGNED=/dev/stdin \
            O=${output_dir}/${sample}.umi.merged.BAM \
            R=$hg38 \
            SO=coordinate \
            ALIGNER_PROPER_PAIR_FLAGS=true \
            MAX_GAPS=-1 \
            ORIENTATIONS=FR \
            VALIDATION_STRINGENCY=SILENT \
            CREATE_INDEX=true \
            TMP_DIR="$TMP_DIR"
    "
}

# Main pipeline execution
main() {
    create_directories
    check_tools
    convert_fastq_to_ubam
    extract_umis
    align_genome
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Pipeline completed successfully!" | tee -a "$log_file"
}

# Execute the main function
main