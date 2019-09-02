#!/usr/bin/env bash

# setting colors to use
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

## help info ##
# called by program name with no arguments or with "-h" as only positional argument
if [ "$#" == 0 ] || [ $1 == "-h" ] || [ $1 == "help" ]; then


    printf "\n --------------------------------  HELP INFO  --------------------------------- \n\n"
    printf "  This program downloads assembly files for NCBI genomes. It takes as input\n"
    printf "  assembly accessions (either GCA_* or GCF_*) and optionally a specification of\n"
    printf "  which format to download (currently: genbank, fasta, protein, or gff).\n\n"

    printf "    Required input:\n\n"
    printf "        - [-w <file>] single-column file of NCBI assembly accessions\n\n"

    printf "    Optional arguments include:\n\n"

    printf "        - [-f <str>] default: genbank\n"
    printf "                  Specify the desired format. Available options currently\n"
    printf "                  include genbank, fasta, protein, or gff.\n\n"

    printf "        - [-j <int> ] default: 1\n"
    printf "                  The number of downloads you'd like to run in parallel.\n\n"

    printf "    Example usage:\n\n\t bit-dl-ncbi-assemblies -w ncbi_accessions.txt -f protein -j 4\n\n"

    exit
fi

printf "\n"


## setting default ##
format="genbank"
num_jobs=1

## parsing arguments
while getopts :w:f:j: args
do
    case "${args}"
    in
        w) NCBI_acc_file=${OPTARG};;
        f) format=${OPTARG};;
        j) num_jobs=${OPTARG};;
        \?) printf "\n  ${RED}Invalid argument: -${OPTARG}${NC}\n\n    Run 'bit-dl-ncbi-assemblies' with no arguments or '-h' only to see help menu.\n\n" >&2 && exit
    esac
done


## making sure input file was provided ##
if [ ! -n "$NCBI_acc_file" ]; then
    printf "\n  ${RED}You need to provide an input file with NCBI accessions!${NC}\n"
    printf "\nExiting for now.\n\n"
    exit
fi

## making sure format specified is interpretable
if [[ "$format" != "genbank" && $format != "fasta" && $format != "protein" && $format != "gff" ]]; then
    printf "\n  ${RED}Invalid argument passed to \'-f' option: $format\n\n${NC}"
    printf "  Valid options are genbank, fasta, protein, or gff.\n"
    printf "Exiting for now.\n\n"
    exit
fi


## checking no duplicates in input file ##
if [ -f "$NCBI_acc_file" ]; then
    num_dupes=$(uniq -d "$NCBI_acc_file" | wc -l | sed "s/^ *//" | cut -d " " -f 1)
    if [ ! $num_dupes == 0 ]; then
        printf "\n${RED}      $NCBI_acc_file has duplicate entries, check it out and provide unique accessions only.${NC}\n"
        printf "\nExiting for now.\n\n"
        exit
    fi
fi


## making sure input file is there, and storing total number of targets ##
if [ -f "$NCBI_acc_file" ]; then
    NCBI_input_genomes_total=$(wc -l $NCBI_acc_file | sed "s/^ *//" | cut -d " " -f 1)
    printf "    Targeting $NCBI_input_genomes_total genomes in $format format.\n\n"
else
    printf "\n${RED}      You specified $NCBI_acc_file, but that file cannot be found :(${NC}\n"
    printf "\nExiting for now.\n\n"
    exit
fi


## downloading assembly summaries (if not present in cwd) ##
if [ ! -s ncbi_assembly_info.tsv ]; then

    printf "    ${GREEN}Downloading ncbi assembly summaries to be able to construct ftp links...${NC}\n\n"
    curl --connect-timeout 30 --retry 10 ftp://ftp.ncbi.nlm.nih.gov/genomes/genbank/assembly_summary_genbank.txt -o ncbi_assembly_info.tsv || echo "failed" > capture_any_dl_errors.tmp

    # making sure file downloaded with no errors
    if [ -s capture_any_dl_errors.tmp ]; then
        printf "\n\n  ${RED}Download of NCBI assembly summaries failed :(${NC}\n  Is your internet connection weak?\n\nExiting for now.\n\n"
        rm -rf capture_any_dl_errors.tmp ncbi_assembly_info.tsv
        exit
    else
        rm -rf capture_any_dl_errors.tmp
    fi

    curl --connect-timeout 30 --retry 10 ftp://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt -o ncbi_RS_assembly_info.tmp || echo "failed" > capture_any_dl_errors.tmp

    # making sure file downloaded with no errors
    if [ -s capture_any_dl_errors.tmp ]; then
        printf "\n\n  ${RED}Download of NCBI assembly summaries failed :(${NC}\n  Is your internet connection weak?\n\nExiting for now.\n\n"
        rm -rf capture_any_dl_errors.tmp ncbi_assembly_info
        exit
    else
        rm -rf capture_any_dl_errors.tmp
        cat ncbi_RS_assembly_info.tmp >> ncbi_assembly_info.tsv
        rm ncbi_RS_assembly_info.tmp
    fi

    printf "\n"
fi


## parsing assembly summaries and generating base ftp link info tab ##
tmp_file=$(date +%s).bit-dl-ncbi.tmp
bit-parse-assembly-summary-file -a ncbi_assembly_info.tsv -w $NCBI_acc_file -o $tmp_file

## setting proper extention for download ##
if [ $format == "genbank" ]; then
    ext="_genomic.gbff"
    my_ext=".gb"
elif [ $format == "fasta" ]; then
    ext="_genomic.fna"
    my_ext=".fa"
elif [ $format == "protein" ]; then
    ext="_protein.faa"
    my_ext=".faa"
elif [ $format == "gff" ]; then
    ext="_genomic.gff"
    my_ext=".gff"
fi


### running downloads in serial, unless specified to run in parallel ###
if [ $num_jobs == "1" ]; then

    while IFS=$'\t' read -r -a curr_line

    do

        assembly="${curr_line[0]}"
        downloaded_accession="${curr_line[1]}"
        num=$((num+1))

        printf "\r\t Numero $num of $NCBI_input_genomes_total: $assembly"

        # storing and building links
        base_link="${curr_line[8]}"

        # checking link was actually present (sometimes, very rarely, it is not there)
        # if not there, attempting to build ourselves
        if [ $base_link == "na" ] || [ -z $base_link ]; then

            p1=$(printf "ftp://ftp.ncbi.nlm.nih.gov/genomes/all")

            # checking if GCF or GCA
            if [[ $assembly == "GCF"* ]]; then 
                p2="GCF"
            else
                p2="GCA"
            fi
            
            p3=$(echo $assembly | cut -f 2 -d "_" | cut -c 1-3)
            p4=$(echo $assembly | cut -f 2 -d "_" | cut -c 4-6)
            p5=$(echo $assembly | cut -f 2 -d "_" | cut -c 7-9)

            ass_name="${curr_line[2]}"
            end_path=$(paste -d "_" <(echo "$assembly") <(echo "$ass_name"))

            base_link=$(paste -d "/" <(echo "$p1") <(echo "$p2") <(echo "$p3") <(echo "$p4") <(echo "$p5") <(echo "$end_path"))

        else

            end_path=$(basename $base_link)
        
        fi

        # attempting to download genes for assembly
        curl --silent --retry 10 -o ${assembly}${my_ext}.gz "${base_link}/${end_path}${ext}.gz"

        if [ -s ${assembly}${my_ext}.gz ]; then
            gunzip ${assembly}${my_ext}.gz

        else
            
            printf "\n     ${RED}******************************* ${NC}NOTICE ${RED}*******************************${NC}  \n"
            printf "\t  $assembly's $format file didn't download successfully.\n\n"
            printf "\t  Written to \"Failed_accessions.txt\".\n"
            printf "     ${RED}********************************************************************** ${NC}\n\n"

            echo ${assembly} >> Failed_accessions.txt

        fi

    done < $tmp_file

else
    cat $tmp_file | parallel -j $num_jobs helper-bit-dl-ncbi-assemblies-parallel.sh {} $my_ext $ext
fi

rm $tmp_file

printf "\n\n\t\t\t  ${GREEN}DONE!${NC}\n\n"