#!/bin/bash
###~ description: archives and backs up filed and folders specified in the csv file
###  csv file format: archive name, folder to backup

#~ get variables
destinationForBackups="$PWD/data"                             # yedek konumunu degistirirsin
programLogDirectory="$(mktemp -d)"

#~ define file if gives argument
[[ -n "$1" ]] && csvFile="$1" || { echo "CSV file is not defined" && exit 1; }



#~ check folders from csv
checkFoldersFromCsv() {
    local folderlist="$(cat $csvFile | sed '1d')"
    for a in $folderlist; do
        local folderpath="$(echo $a | cut -d ',' -f2)"
        [[ -d $folderpath ]] && { echo $folderpath >> $programLogDirectory/existsfolders; } || { echo $folderpath >> $programLogDirectory/notexistsfolders; }
    done

    local numberOfFolders=$(echo "$folderlist" | wc -l)
    [[ -e $programLogDirectory/existsfolders    ]] && local numberOfExistsFolders=$(cat $programLogDirectory/existsfolders | wc -l)
    [[ -e $programLogDirectory/notexistsfolders ]] && local numberOfNotExistsFolders=$(cat $programLogDirectory/notexistsfolders | wc -l)
    echo -e "SUMMARY\n\tFiles     : $numberOfFolders\n\tExists    : ${numberOfExistsFolders:-0}\n\tNot Exists: ${numberOfNotExistsFolders:-0}"
}



#~ create chunks
createChunks() {
    local folderchunks="$(cat $csvFile | sed '1d' | cut -d ',' -f1)"
    for a in $(echo $folderchunks | awk -F ',' '{print $1}'); do
        echo $a >> $programLogDirectory/chunks
    done
    echo "\"$(ls $destinationForBackups/archive | wc -l)\" chunks found..."
}



#~ fill and archive chunks
fillAndArchiveChunks() {
    for a in $(cat $programLogDirectory/chunks); do
        local folderpath="$(cat $csvFile | grep $a | cut -d ',' -f2)"
        rsync -avrl $folderpath $destinationForBackups/attachments/$a --log-file=$programLogDirectory/rsync-$(date +%Y-%m-%d_%H-%M-%S).log >>/dev/null
        7za a -m0=lzma2 -mx=9 $destinationForBackups/archive/${a}-compressed.7z $destinationForBackups/attachments/$a &>/dev/null
        echo "Fill chunk: $a: $(ls $destinationForBackups/attachments/$a | wc -l)"
    done
}



#~ main process
main() {
    mkdir -p $destinationForBackups/{archive,attachments}
    checkFoldersFromCsv
    createChunks
    fillAndArchiveChunks
    rm -rf $programLogDirectory
}

main

