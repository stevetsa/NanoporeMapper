#!/bin/bash

MAGIC_BLAST_DIR=/home/ubuntu/bastian/ncbi-magicblast-1.3.0
WORK_DIR="$(pwd)"
OUT_DIR="$(pwd)"
programname=$0
version="0.1"
MB_SCORE=30

function usage {
	echo "usage:  $programname -s sraAccessions -d existingDBName [-e|-i taxList] [-m  magicBlastDir] [-o outDir] [-w workDir]"
	echo ""
	echo "  -s sraAccessions	Comma-separated list of SRA accessions to map against reference genomes.  Do not include spaces."
	echo "  -d existingDBName	Reference database name - always required."
	echo "  -e taxList		Blacklist of taxonomy indicators - magicBlast will keep only sequence reads that could not be mapped to these genomes."
	echo "  -i taxList		Whitelist of taxonomy indicators - magicBlast will keep only sequence reads that could be mapped to these genomes."
	echo "  -m magicBlastDir	Specify the (existing) directory that contains the bin/magicblast - default is "$MAGIC_BLAST_DIR
	echo "  -o outDir		Specify the (existing) directory for output files - default is the current directory."
	echo "  -t magicblastScoreThreshold Specify either a single integer value or the parameters of the linear model a,b -default is "$MB_SCORE
	echo "  -w workDir		Specify the (existing) directory for reference genome data - default is the current directory."
	echo ""
	echo "  A whitelist or a blacklist can be provided, but not both.  If neither is provided, the reference database should already exist."
	echo "  Otherwise, the reference database will be created based on the whitelist/blacklist."
	echo ""
	documentTaxList

}

function documentTaxList {
	echo "  Blacklist and whitelist can currently be any format that ncbi-genome-downloader supports:"
	echo "  * Any of these groups does not need to be quoted: "
	echo "  	all,archaea,bacteria,fungi,invertebrate,plant,protozoa,unknown,vertebrate_mammalian,vertebrate_other,viral"
	echo "  * Any of these sub-group specifications must be quoted, e.g. \"--taxid 199310 bacteria\""
	echo "  	--genus or -g, --taxid or -t, --species-taxid or -T"
	echo "  Caveats:"
	echo "    The released ncbi-genome-downloader currently does not accept a comma-separated list."
	echo "    Multi-word specifications (e.g. Streptomyces coelicolor) are not supported here."  # This is because we completely unquote the taxList
}


echo "STREAMclean, version "$version

# Basic flag option validation
if [ $# -eq 0 ]; then     # Cannot be called meaningfully without flags
	usage
	exit 0
fi

while getopts ":d:e:i:m:o:s:t:w:" o; do
    case "${o}" in
        d)
	    BLAST_DB_NAME=${OPTARG}
	    ;;
	e)
            EXCLUDE_TAX=${OPTARG}
            ;;
        i)
            INCLUDE_TAX=${OPTARG}
            ;;
	m)
	    MAGIC_BLAST_DIR=${OPTARG}
	    ;;
	o)
	    OUT_DIR=${OPTARG}
	    ;;
	s)
	    SRA_ACCESSIONS=${OPTARG}
	    ;;
	t)
	    MB_SCORE=${OPTARG}
	    ;;
	w)
	    WORK_DIR=${OPTARG}
	    ;;
	:)
	   echo  "Invalid option: $OPTARG requires an argument"
	   usage
	   exit 0
	   ;;
        \?)
            usage
	    exit 0
            ;;
    esac
done
shift $((OPTIND-1))

# More sophisticated validation
if [ ! -d "$WORK_DIR" ]; then
  echo "$WORK_DIR" does not exist - exiting.
  exit 0
fi

if [ ! -d "$OUT_DIR" ]; then
  echo "$OUT_DIR" does not exist - exiting.
  exit 0
fi

if [ ! -d "$MAGIC_BLAST_DIR" ]; then
  echo "$MAGIC_BLAST_DIR" does not exist - exiting.
  exit 0
fi

if [ -z "$BLAST_DB_NAME" ]; then
  echo "Please supply the name of a reference database to use."
  exit 0
fi

if [ -n "$EXCLUDE_TAX" ] && [ -n "$INCLUDE_TAX" ]; then
  echo "Both a whitelist and blacklist were provided.  This is not currently supported."
  exit 0
fi

# Assumption: Uses na1 file existence as a proxy for the reference db having been created.
BLAST_DB_PATH="$WORK_DIR/$BLAST_DB_NAME"
if [ -z "$EXCLUDE_TAX" ] && [ -z "$INCLUDE_TAX" ] && [ !  -f "$BLAST_DB_PATH".na1 ]; then
  echo "When neither a whitelist nor a blacklist exists, the reference database must already exist.  This file does not exist: $BLAST_DB_PATH.na1"
  exit 0
fi
# End of Validation

# Download reference genomes and make database if necessary
if [ -n "$EXCLUDE_TAX" ] || [ -n "$INCLUDE_TAX" ]; then
  # TODO: this is where we should plug in the download size/time estimator

REFSEQ_DIR="$WORK_DIR/refseq"
  echo Reference genome files will be loaded in this working directory and can be deleted afterwards: "$REFSEQ_DIR"
  echo Creating reference database "$BLAST_DB_NAME" in "$WORK_DIR".

  # ncbi-genome-download will be a dependency
  # ncbi-genome-download does not actually support comma-separated list (even though it's supposed to)
  # Omit quotes around $EXCLUDE_TAX and $INCLUDE_TAX in order to expand user-entered quoted argument to pass directly to genome downloader
  if [ -n "$EXCLUDE_TAX" ]; then
    ncbi-genome-download -F fasta -o "$WORK_DIR" $EXCLUDE_TAX 2>"$OUT_DIR/nanoporeMapperErrors.log"
  fi
  if [ -n "$INCLUDE_TAX" ]; then
    ncbi-genome-download -F fasta -o "$WORK_DIR" $INCLUDE_TAX 2>"$OUT_DIR/nanoporeMapperErrors.log"
  fi

  # Dev Comment: this line is for testing
#  ncbi-genome-download --format fasta --taxid 199310 bacteria
  wait

  # Exit if the genome download did not succeed. ncbi-genome-download does not return failure codes nor expose accessors for the list of valid inputs.
  if [ ! -d "$REFSEQ_DIR" ]; then
    echo Failed to download reference genome data.  See "$OUT_DIR/nanoporeMapperErrors.log"
    exit 1
  fi

  # concat the FASTA files (currently only working with FASTA format)
  find "$REFSEQ_DIR"/ -name '*.fna.gz' | xargs zcat >>"$BLAST_DB_PATH".fna
  # I couldn't get makeblastdb accept gzipped FASTAs, uncomment when we alter the makeblastdb command to accept gzip.
  # find "$REFSEQ_DIR"/ -name '*.fna.gz' | xargs cat >"$BLAST_DB_PATH".fna.gz

  # build the magic-blast database
  "$MAGIC_BLAST_DIR"/bin/makeblastdb -in "$BLAST_DB_PATH".fna -dbtype nucl -parse_seqids -out "$BLAST_DB_PATH"
else
  echo Using existing reference database "$BLAST_DB_PATH"
fi

# magic-blast alignments, the first python script needs to run at the same
# time, otherwise we won't get the benefit of streaming
for SRA_ACC in $(echo $SRA_ACCESSIONS | sed "s/,/ /g") 
do
	SAM_PATH="$WORK_DIR/"$SRA_ACC"_magicblast.sam"
	if [ -n "$INCLUDE_TAX" ]; then
		"$MAGIC_BLAST_DIR"/bin/magicblast -sra "$SRA_ACC" -db "$BLAST_DB_PATH" -gapextend 0 | \
		python streamin_magicblast.py -m include -s "$MB_SCORE" > "$SAM_PATH"
	else
		"$MAGIC_BLAST_DIR"/bin/magicblast -sra "$SRA_ACC" -db "$BLAST_DB_PATH" -gapextend 0 | \
		python streamin_magicblast.py -m exclude -s "$MB_SCORE" > "$SAM_PATH"
	fi
done


# filter magic-blasted reads
for SRA_ACC in $(echo $SRA_ACCESSIONS | sed "s/,/ /g") 
do
	cat "$WORK_DIR/$SRA_ACC"_magicblast.sam | python streamin_sam_to_reads.py  > "$OUT_DIR/$SRA_ACC"_magicblast.fasta
done
