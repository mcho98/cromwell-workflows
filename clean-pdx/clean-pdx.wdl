version 1.0 

## Copyright Aparicio Lab (BC Cancer Research Centre), 2022 
## Created by Jenna Liebe
##
## Last Updated: September 18, 2023 by Matthew Cho - changed output_basename under ConvertPairedFastQsToUnmappedBamWf call
## 
## This WDL pipeline strips out mouse reads from an input PDX (patient-derived xenograft) file
## in BAM format, by performing alignment to a chimeric mouse-human (mm10-hg38) reference
## genome and then removing all reads that more closely align to mouse reads.
##
## Requirements/expectations :
## - PDX sample reads in BAM format
## - Sample information, including:
##   - Sample ID
##   - Sample read-group ID (RGID)
##   - Sample PU
##   - Sample SM
##   - Sample PL (most likely ILLUMINA)
## - Chimeric reference genome (current version: mm10/hg38) in FASTA format
##   - Reference dictionary (.fa.dict)
##   - Reference fasta index (.fa.fai)
## - Chimeric reference BWA Index files (can be generated via BWA index)
##   - Note - .alt file is not required
##
## Runtime parameters are optimized for Microsoft's CromwellOnAzure implementation.


# WORKFLOW DEFINITION
workflow CleanPDX {
	input {
    String study # metadata for clean-up automation 
    
		File input_bam
		String sample_ID
    String sample_RGID
    String sample_PU
    String sample_SM
    String sample_PL

    # Combo mouse/human references:
    File mouse_human_genome_fasta
    File mouse_human_genome_fasta_index
    File mouse_human_genome_dict 

	Int num_threads = 20

    String bwa_commandline = "bwa mem -K 100000000 -p -v 3 -t 16 -Y $bash_ref_fasta"

		String gotc_docker = "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    String gotc_path = "/usr/gitc/"
		Int compression_level = 5
		Int preemptible_tries = 2
	}

  call Flagstat {
    input: 
      input_bam = input_bam, 
      output_name = sample_ID + ".raw.flagstat.txt"
  }

  call WriteFlagstatOut {
    input: 
      input_flagstat = Flagstat.output_file, 
      output_name = sample_ID + ".writeout.raw.flagstat.txt", 
      sample_ID = sample_ID
  }

	# Get the BWA version to use for alignment
	call GetBwaVersion


	# Convert input_bam to paired fastq reads
	call SamToFastqAndBwaMem {
    input:
      input_bam = input_bam,
      bwa_commandline = bwa_commandline,
      output_bam_basename = sample_ID + ".aligned.unsorted",
      mouse_human_genome_fasta = mouse_human_genome_fasta,
      mouse_human_genome_fasta_index = mouse_human_genome_fasta_index,
      mouse_human_genome_dict = mouse_human_genome_dict,
      bwa_version = GetBwaVersion.bwa_version,
      compression_level = compression_level,
      preemptible_tries = 1,
      gotc_docker = gotc_docker
  }


  # Sort the output of SamToFastqAndBwaMem so that it can be filtered
  call SortBwaBam {
  	input:
  		input_bam = SamToFastqAndBwaMem.output_bam,
  		output_bam_basename = sample_ID + ".aligned.sorted",
  		compression_level = compression_level,
  		preemptible_tries = preemptible_tries,
  		gotc_docker = gotc_docker
  }


  # Filter out mouse alignments from the sorted BAM file
  call FilterReads {
  	input:
  		input_bam = SortBwaBam.output_bam,
  		output_bam_basename = sample_ID + ".sorted.filtered",
  		preemptible_tries = preemptible_tries,
  		gotc_docker = gotc_docker
  }


  # Sort the BAM by queryname and then extract non-mouse reads by converting to FASTQ
  call SortAndExtract {
    input:
      input_bam = FilterReads.output_bam,
      output_fastq_basename = sample_ID + ".sorted.hgonly",
      output_fastq_basename2 = sample_ID + ".2.sorted.hgonly",
      preemptible_tries = preemptible_tries,
      gotc_docker = gotc_docker
  }

  # https://github.com/gatk-workflows/seq-format-conversion/blob/master/paired-fastq-to-unmapped-bam.wdl
  # Convert paired FASTQs to 1 uBAM
  # adds a boolean flag (true for either setSecondOfPairFlag or setFirstOfPairFlag), which Flagstat will be able to interpret. 
  call ConvertPairedFastQsToUnmappedBamWf {
    input: 
      sample_ID = sample_ID, 
      fastq_1 = SortAndExtract.output_fastqs[0], 
      fastq_2 = SortAndExtract.output_fastqs[1],
      unsorted_bam_basename = basename(SortAndExtract.output_fastqs[0]) + ".unsorted.unmapped.bam", 
      gotc_docker = gotc_docker
  }

  String output_basename = basename(ConvertPairedFastQsToUnmappedBamWf.output_unmapped_bam, ".fastq.unsorted.unmapped.bam")

  call FinalSort {
    input:
      input_bam = ConvertPairedFastQsToUnmappedBamWf.output_unmapped_bam,
      sorted_bam_basename = output_basename + ".sorted.unmapped",
      compression_level = compression_level,
      preemptible_tries = preemptible_tries,
      gotc_docker = gotc_docker
  }

  call Reheader {
    input:
      input_bam = FinalSort.sorted_bam,
      sample_ID = sample_ID,
      sample_RGID = sample_RGID,
      sample_PU = sample_PU,
      sample_SM = sample_SM,
      sample_PL = sample_PL,
      output_bam_basename = output_basename + ".final.unmapped",
      compression_level = compression_level,
      preemptible_tries = preemptible_tries,
      gotc_docker = gotc_docker
  }

  call GetBamHeader {
    input: 
      input_bam = Reheader.output_bam, 
      output_name = output_basename + ".bam.header.txt"
  }

  output {
    File flagstat_writeout = WriteFlagstatOut.output_file
  }
}


# TASK DEFINITIONS

task Flagstat {
  input {
    File input_bam
    String output_name
  }

  Int disk = ceil(size(input_bam, "GB") * 2)
    
  command <<< 
    samtools flagstat ~{input_bam} > ~{output_name}
  >>>

  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    disk: disk + " GB"
    cpu: 4
    preemptible: true
  }

  output {
    File output_file = "~{output_name}"
  }
}

task WriteFlagstatOut {
  input {
    File input_flagstat
    String output_name
    String sample_ID
  }

  command <<<
    head -1 ~{input_flagstat} > temp.txt
    VAR=$(awk -F ' ' '{print $1, $3}' temp.txt)
    echo -n ~{sample_ID} >> ~{output_name}
    echo -n " " >> ~{output_name}
    echo -n $VAR >> ~{output_name}
    rm temp.txt
  >>>

  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    cpu: 4
    preemptible: true
  }

  output { 
    File output_file = "~{output_name}"
  }
}
	
# Get the BWA version to use for alignment
task GetBwaVersion {
  command {
    # not setting set -o pipefail here because /bwa has a rc=1 and we dont want to allow rc=1 to succeed because
    # the sed may also fail with that error and that is something we actually want to fail on.
    /usr/gitc/bwa 2>&1 | \
    grep -e '^Version' | \
    sed 's/Version: //'
  }
  
  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.5.7-2021-06-09_16-47-48Z"
    memory: "1 GB"
  }

  output {
    String bwa_version = read_string(stdout())
  }
}


# Convert input_bam to paired fastq reads and aligns to a combined mouse/human reference
task SamToFastqAndBwaMem {
	input {
    	File input_bam
    	String bwa_commandline
    	String bwa_version
    	String output_bam_basename
    	
      File mouse_human_genome_fasta
      File mouse_human_genome_fasta_index
      File mouse_human_genome_dict

      File mouse_human_genome_sa
      File mouse_human_genome_amb
      File mouse_human_genome_ann
      File mouse_human_genome_bwt
      File mouse_human_genome_pac
      File? mouse_human_genome_alt

    	Int compression_level
    	Int preemptible_tries

    	String gotc_docker
	}

  Float unmapped_bam_size = size(input_bam, "GB")

  # Since ref_size/bwa_ref_size don't like getting the size of the input ref files, just estimate that total is ~15GB and add to disk_size

  # Sometimes the output is larger than the input, or a task can spill to disk.
  # In these cases we need to account for the input (1) and the output (1.5) or the input(1), the output(1), and spillage (.5).
  Float disk_multiplier = 2.5
  Int disk_size = ceil(unmapped_bam_size + 16 + (disk_multiplier * unmapped_bam_size) + 200)

	command <<<
    set -o pipefail
    set -e
    # set the bash variable needed for the command-line
    bash_ref_fasta=~{mouse_human_genome_fasta}
    java -Xms3000m -jar /usr/gitc/picard.jar \
    SamToFastq \
    INPUT=~{input_bam} \
    FASTQ=/dev/stdout \
    INTERLEAVE=true \
    VALIDATION_STRINGENCY=LENIENT \
    NON_PF=true | \
    /usr/gitc/~{bwa_commandline} /dev/stdin - 2> >(tee ~{output_bam_basename}.bwa.stderr.log >&2) | \
    samtools view -1 - > ~{output_bam_basename}.bam
	>>>

	runtime {
		docker: gotc_docker
		preemptible: true
		maxRetries: preemptible_tries
		memory: "24 GB"
		cpu: 18
		disk: disk_size + " GB"
	}

	output {
    	File output_bam = "~{output_bam_basename}.bam"
    	File bwa_stderr_log = "~{output_bam_basename}.bwa.stderr.log"
   	}
}


# Sort the BAM file outputted by BWA mem
task SortBwaBam {
  input {
    File input_bam
    String output_bam_basename
    
    Int preemptible_tries
    Int compression_level

    String gotc_docker
  }

  # SortBwaBam spills to disk a lot more because we are only store 300000 records in RAM now because its faster for our data so it needs
  # more disk space.  Also it spills to disk in an uncompressed format so we need to account for that with a larger multiplier
  
  Float sort_sam_disk_multiplier = 3.25
  Int disk_size = ceil(sort_sam_disk_multiplier * size(input_bam, "GB")) + 20

  command <<<
    java -Dsamjdk.compression_level=~{compression_level} -Xms4000m -jar /usr/gitc/picard.jar \
    SortSam \
    INPUT=~{input_bam} \
    OUTPUT=~{output_bam_basename}.bam \
    SORT_ORDER="coordinate" \
    CREATE_INDEX=true \
    CREATE_MD5_FILE=false \
    MAX_RECORDS_IN_RAM=300000
  >>>

  runtime {
    docker: gotc_docker
    disk: disk_size + " GB"
    cpu: 8
    memory: "5000 MB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File output_bam = "~{output_bam_basename}.bam"
    File output_bam_index = "~{output_bam_basename}.bai"
  }
}


# Filter out mouse alignments from the sorted BAM file
task FilterReads {
	input {
		File input_bam
		String output_bam_basename
		
		Int preemptible_tries
		
		String gotc_docker
	}

	Float input_bam_size = size(input_bam, "GB")
	Int disk_size = ceil(input_bam_size * 2.5)

	command <<<
    set -o pipefail
    set -e
    samtools view -h ~{input_bam} |
    awk '{if($3 !~ /m_chr/){print $0}}' |
    samtools view -Shb - > ~{output_bam_basename}.bam
	>>>

	runtime {
		docker: gotc_docker
		memory: "16 GB"
		cpu: 16
		disk: disk_size + " GB"
		preemptible: true
		maxRetries: preemptible_tries
	}

	output {
    File output_bam = "~{output_bam_basename}.bam"
  }
}


# Sort the BAM by queryname and then extract non-mouse reads by converting to FASTQ
task SortAndExtract {
  input {
    File input_bam
    String output_fastq_basename
    String output_fastq_basename2
    
    Int preemptible_tries
    String gotc_docker
  }

  Float input_bam_size = size(input_bam, "GB")
  Int disk_size = ceil(input_bam_size * 7) + 40 # + 0 -> + 40

  command <<<
    set -o pipefail
    set -e
    java -Xms4000m -jar /usr/gitc/picard.jar \
    SortSam \
    INPUT=~{input_bam} \
    OUTPUT=/dev/stdout \
    SORT_ORDER="queryname" \
    MAX_RECORDS_IN_RAM=300000 | \
    samtools fastq -1 ~{output_fastq_basename}.fastq -2 ~{output_fastq_basename2}.fastq -0 /dev/null -s /dev/null /dev/stdin 
  >>>

  runtime {
    docker: gotc_docker
    memory: "45 GB" # test failed at sort + extract, 32 GB -> 40 GB
    cpu: 45 # 32 -> 40
    disk: disk_size + " GB"
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    Array[File] output_fastqs = glob("*.fastq")
  }
}

# https://github.com/gatk-workflows/seq-format-conversion/blob/master/paired-fastq-to-unmapped-bam.wdl 
task ConvertPairedFastQsToUnmappedBamWf {
  input {
    # Command parameters
    String sample_ID
    File fastq_1
    File fastq_2
    String unsorted_bam_basename
    String gotc_docker
    
    # Runtime parameters
    Int preemptible_tries = 3
    Float disk_multiplier = 2.5
  }
  
  Float fastq_size = size(fastq_1, "GB") + size(fastq_2, "GB")
  Int disk_size = ceil(fastq_size + (fastq_size * disk_multiplier ) + 10)
  
  command <<<
    java -Xms4000m -jar /usr/gitc/picard.jar \
    FastqToSam \
    F1=~{fastq_1} \
    F2=~{fastq_2} \
    O=~{unsorted_bam_basename} \
    SM=~{sample_ID} \
    SORT_ORDER=queryname \
    MAX_RECORDS_IN_RAM=300000
  >>>

  runtime {
    docker: gotc_docker
    memory: "24 GB"
    disk: disk_size + " GB"
    cpu: 16
    preemptible: true
    maxRetries: preemptible_tries
  }
  output {
    File output_unmapped_bam = "~{unsorted_bam_basename}"
  }
}


task FinalSort {
  input {
    File input_bam
    String sorted_bam_basename

    Int preemptible_tries
    Int compression_level
    
    String gotc_docker
  }

  Float sort_sam_disk_multiplier = 5
  Int disk_size = ceil(sort_sam_disk_multiplier * size(input_bam, "GB")) + 20

  command <<<
    java -Xms4000m -jar /usr/gitc/picard.jar \
    SortSam \
    INPUT=~{input_bam} \
    OUTPUT=~{sorted_bam_basename}.bam \
    SORT_ORDER="queryname" \
    CREATE_INDEX=true \
    CREATE_MD5_FILE=true \
    MAX_RECORDS_IN_RAM=300000
  >>>

  runtime {
    docker: gotc_docker
    memory: "24 GB"
    disk: disk_size + " GB"
    cpu: 18
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File sorted_bam = "~{sorted_bam_basename}.bam"
  }
}

task Reheader {
  input {
    File input_bam
    String sample_ID
    String sample_RGID
    String sample_PU
    String sample_SM
    String sample_PL
    String output_bam_basename

    Int preemptible_tries
    Int compression_level
    
    String gotc_docker
  }

  Float input_bam_size = size(input_bam, "GB")
  Int disk_size = ceil(input_bam_size * 3)

  command <<<
    java -Xms4000m -jar /usr/gitc/picard.jar \
    AddOrReplaceReadGroups \
    INPUT=~{input_bam} \
    OUTPUT=~{output_bam_basename}.bam \
    RGID=~{sample_RGID} \
    RGLB=~{sample_ID} \
    RGPL=~{sample_PL} \
    RGPU=~{sample_PU} \
    RGSM=~{sample_SM}
  >>>

  runtime {
    docker: gotc_docker
    memory: "12 GB"
    disk: disk_size + " GB"
    cpu: 4
    preemptible: true
    maxRetries: preemptible_tries
  }

  output {
    File output_bam = "~{output_bam_basename}.bam"
  }
}

task GetBamHeader {
  input {
    File input_bam
    String output_name
  }

  Int disk = ceil(size(input_bam, "GB") * 2)

  command <<<
    samtools view -H > ~{output_name}
  >>>

  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    disk: disk + " GB"
    cpu: 4
    preemptible: true
  }

  output {
    File output_file = "~{output_name}"
  }
}

