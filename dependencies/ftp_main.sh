#!/bin/bash
s_version="0.91"

############## CODE STARTS HERE ##################
script="$(readlink -f $0)"
scriptdir=$(dirname $script)
scriptdir=${scriptdir%/dependencies}

function delay {
# if --delay is set, wait until it ends. If start/end time is set in config use them. Delay overrules everything
		if [[ -n $date_time ]]; then
			current_epoch=$(date +%s)
			target_epoch=$(date -d "$date_time" +%s)
			sleep_seconds=$(( $target_epoch - $current_epoch ))
			echo "Transfere has been postponed until $date_time"
			sleep $sleep_seconds
		elif [[ -n $transfer_start ]] && [[ -n $transfer_end ]] && [[ $force == "false" ]]; then
			tranfere_timeframe
		fi
}

function date2stamp () {
    date --utc --date "$1" +%s
}

function dateDiff (){
    case $1 in
        -s)   sec=1;      shift;;
        -m)   sec=60;     shift;;
        -h)   sec=3600;   shift;;
        -d)   sec=86400;  shift;;
        *)    sec=86400;;
    esac
    dte1=$(date2stamp $1)
    dte2=$(date2stamp $2)
    diffSec=$((dte2-dte1))
    if ((diffSec < 0)); then abs=-1; else abs=1; fi
    echo $((diffSec/sec*abs))
}

function tranfere_timeframe {
	#start/end in format "14:30"
	if [[ "$transfere_start" > $(date +%R) ]] && [[ "$transfere_end" < $(date +%R) ]];  then
		echo "everthing is ok" &> /dev/null
	else
		kill -9 "$pid_transfer"
		sleep_seconds=$(dateDiff -s "$(date +%T)" "$transfere_start+24:00")
		echo "Time is $(date +%R), transfer is postponed until $transfere_start"
		sed "5s#.*#***************************	Transfering: $orig_name - waiting to start at $transfere_Start  #" -i $logfile
		sleep $sleep_seconds
		ftp_transfere
	fi
}

function queue {
# queuesystem. If something already is running for the user, add it to queue.
	local option=$2
	case "$1" in
		"add" )
				queue="true"
				if [[ $queue_run != "true" ]]; then
					# figure out ID
					if [[ -e "$queue_file" ]]; then
						#get last id
						id=$(( $(tail -1 "$queue_file" | cut -d'#' -f1) + 1 ))
					else
						#assume this is the first one
						id="1"
					fi
					if [[ -e "$scriptdir/plugins/addon.sh" ]]; then
						flexget_feed
					fi
					get_size "$filepath" "exclude_array[@]" &> /dev/null
					if [[ -e "$queue_file" ]] && [[ -n $(cat "$queue_file" | grep $(basename "$filepath")) ]]; then
						echo "INFO: Item already exists. Doing nothing."
						exit 0
					elif [[ "$option" == "end" ]]; then
						source=$source"Q"
						echo "INFO: Adding $(basename $filepath) to queue with id=$id"
						echo "$id#$source#$filepath#$size"MB"#$(date '+%d/%m/%y-%a-%H:%M:%S')" >> "$queue_file"
						echo
						exit 0
					else
						echo "INFO: Adding $(basename $filepath) to queue with id=$id"
						echo "$id#$source#$filepath#$size"MB"#$(date '+%d/%m/%y-%a-%H:%M:%S')" >> "$queue_file"
					fi
				fi
		;;
		"remove" )
				#remove item acording to id
				sed "/^"$id"\#/d" -i "$queue_file"
		;;
		"run" )
			if [[ -f "$queue_file" ]] && [[ -n $(cat "$queue_file") ]]; then
				echo "Running queue"
				#load next item from top
				id=$(awk 'BEGIN{FS="|";OFS=" "}NR==1{print $1}' "$queue_file" | cut -d'#' -f1)
				source=$(awk 'BEGIN{FS="|";OFS=" "}NR==1{print $1}' "$queue_file" | cut -d'#' -f2)
				next=$(awk 'BEGIN{FS="|";OFS=" "}NR==1{print $1}' "$queue_file" | cut -d'#' -f3)
				queue_run="true"
				#Reload config. Things might have changed
				loadConfig
				main "$next"
			else
				echo "Empty queue"
				if [[ -f "$queue_file" ]]; then rm "$queue_file"; fi
				echo "Program has ended"
				cleanup end
				exit 0
				echo
			fi
		;;
	esac
}

function ftp_transfere {
	#Cleanup before writing config
	if [[ -f "$ftptransfere_file" ]]; then rm "$ftptransfere_file"; fi
	#prepare new transfer
	{
	cat "$ftplogin_file" >> "$ftptransfere_file"
	# optional use regexp to exclude files during mirror
		if [[ -n "$exclude_array" ]]; then
			local count=0
			for i in "${exclude_array[@]}"; do #second add | to lftp_exclude
				if [[ $count -gt 0 ]]; then
					lftp_exclude="$lftp_exclude|"
				fi
				lftp_exclude="$lftp_exclude^.*$i*"
				let count++
			done
			lftp_exclude="$lftp_exclude$"
			echo "set mirror:exclude-regex \"$lftp_exclude\"" >> "$ftptransfere_file"	
			unset lftp_exclude count
		fi
	# fail if transfers fails
	echo "set cmd:fail-exit true" >> "$ftptransfere_file"
	if [[ $transferetype == "downftp" ]]; then
		# create final directories if they don't exists
		echo "!mkdir -p \"$ftpcomplete\"" >> "$ftptransfere_file"
		echo "!mkdir -p \"$ftpincomplete\"" >> "$ftptransfere_file"
		
		# continue, reverse, locale, remote 
		#for ((i=0;i<=${#filepath[@]};i++)); do
		i=0
		for n in "${filepath[@]}"; do
			if [[ ! -d ${filepath[$i]} ]]; then # single file
				if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
					if [[ $i -eq 0 ]]; then #make sure that directory only is created once
						echo "!mkdir \"$ftpincomplete$changed_name\"" >> "$ftptransfere_file"
					fi
					echo "queue get -c -O \"$ftpincomplete$changed_name\" \"${filepath[$i]}\"" >> "$ftptransfere_file"
					echo "wait"  >> "$ftptransfere_file"
				elif [[ -z $ftpincomplete ]] || [[ $retry_option == "complete" ]]; then
					echo "queue get -c -O \"$ftpcomplete${orig_name[$i]}\" \"${filepath[$i]}\"" >> "$ftptransfere_file"
				fi
			else # directories
				if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
					echo "queue mirror --no-umask -p --parallel=$parallel -c \"${filepath[$i]}\" \"$ftpincomplete\"" >> "$ftptransfere_file"
					echo "wait"  >> "$ftptransfere_file"
				elif [[ -z $ftpincomplete ]] || [[ $retry_option == "complete" ]]; then
					echo "queue mirror --no-umask -p --parallel=$parallel -c \"${filepath[$i]}\" \"$ftpcomplete\"" >> "$ftptransfere_file"
				fi
			fi
			let i++
		done
		# moving part
		if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
			for n in "${changed_name[@]}"; do #using several directories, like in mount
				if [[ "$n" == "$orig_name" ]]; then
					echo "queue !mv \"$ftpincomplete$n/\" \"$ftpcomplete\"" >> "$ftptransfere_file"
				else
					echo "queue !mv \"$ftpincomplete$n/\" \"$ftpcomplete$orig_name\"" >> "$ftptransfere_file"
				fi
				echo "wait"  >> "$ftptransfere_file"
			done
		fi
		 # else assume $retry_option == "complete"
	elif [[ $transferetype == "upftp" ]]; then
		# create final directories if they don't exists
		echo "mkdir -p \"$ftpcomplete\"" >> "$ftptransfere_file"
		echo "mkdir -p \"$ftpincomplete\"" >> "$ftptransfere_file"
		
		# continue, reverse, locale, remote 
		#for ((i=0;i<=${#filepath[@]};i++)); do
		i=0
		for n in "${filepath[@]}"; do
			if [[ ! -d ${filepath[$i]} ]]; then # single file
				if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
					if [[ $i -eq 0 ]]; then #make sure that directory only is created once
						echo "mkdir \"$ftpincomplete$changed_name\"" >> "$ftptransfere_file"
					fi
					echo "queue put -c -O \"$ftpincomplete$changed_name\" \"${filepath[$i]}\"" >> "$ftptransfere_file"
					echo "wait"  >> "$ftptransfere_file"
				elif [[ -z $ftpincomplete ]] || [[ $retry_option == "complete" ]]; then
					echo "queue put -O \"$ftpcomplete${orig_name[$i]}\" \"${filepath[$i]}\"" >> "$ftptransfere_file"
				fi
			else # directories
				if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
					echo "queue mirror --no-umask -p --parallel=$parallel -c -R \"${filepath[$i]}\" \"$ftpincomplete\"" >> "$ftptransfere_file"
					echo "wait"  >> "$ftptransfere_file"
				elif [[ -z $ftpincomplete ]] || [[ $retry_option == "complete" ]]; then
					echo "queue mirror --no-umask -p --parallel=$parallel -c -R \"${filepath[$i]}\" \"$ftpcomplete\"" >> "$ftptransfere_file"
				fi
			fi
			let i++
		done
		# moving part
		if [[ -n $ftpincomplete ]] || [[ $retry_option == "incomplete" ]]; then
			for n in "${changed_name[@]}"; do #using several directories, like in mount
				if [[ "$n" == "$orig_name" ]]; then
					echo "queue mv \"$ftpincomplete$n/\" \"$ftpcomplete\"" >> "$ftptransfere_file"
				else
					echo "queue mv \"$ftpincomplete$n/\" \"$ftpcomplete$orig_name\"" >> "$ftptransfere_file"
				fi
				echo "wait"  >> "$ftptransfere_file"
			done
		fi
		 # else assume $retry_option == "complete"
	elif [[ $transferetype == "fxp" ]]; then #NOT WORKING
		ftppath=${filepath##*/ftp/}
		ftppath=${ftppath%%/$orig_name/}
		echo "set ftp:use-fxp yes" >> "$ftptransfere_file"
		echo "set ftp:fxp-passive-source yes" >> "$ftptransfere_file"
		i=0
		for n in "${changed_name[@]}"; do
			if [[ ! -d ${transfer_path[$i]} ]]; then
				#perhaps not working?
				echo "mkdir \"$ftpincomplete${changed_name[$i]}\"" >> "$ftptransfere_file"
				echo "get ftp://$ftpuser2:$ftppass2@$ftphost2:$ftpport2:\"/$ftppath/${changed_name[$i]}/\" ftp://$ftpuser:$ftppass@$ftphost:$ftpport:\"$ftpincomplete\"" >> "$ftptransfere_file"
			else
				echo "queue mirror --no-umask -p -c --parallel=$parallel ftp://$ftpuser2:$ftppass2@$ftphost2:$ftpport2:\"/$ftppath/${changed_name[$i]}/\" ftp://$ftpuser:$ftppass@$ftphost:$ftpport:\"$ftpincomplete\"" >> "$ftptransfere_file"
			fi
			echo "wait"  >> "$ftptransfere_file"
			echo "queue mv \"$ftpincomplete${changed_name[$i]}\" \"$ftpcomplete${orig_name[$i]}\"" >> "$ftptransfere_file"
			echo "wait"  >> "$ftptransfere_file"
			let i++
		done
	else
		echo -e "\e[00;31mERROR: FTP setting not recognized\e[00m"
		cleanup die
	fi
	echo "quit" >> "$ftptransfere_file"
	}
	 #start transfering
	{
	if [[ $test_mode != "true" ]]; then
		#start progressbar and transfer	
			ftp_processbar $retry_option &
			pid_f_process=$!
			sed "3c $pid_f_process" -i "$lockfile"
			$lftp -f "$ftptransfere_file" &> /dev/null &
			pid_transfer=$!
			sed "2c $pid_transfer" -i "$lockfile"
			wait $pid_transfer
			pid_transfer_status="$?"
			#did lftp end properly
			if [[ $pid_transfer_status -eq 1 ]]; then
				quittime=$(( $scriptstart + $retry_download_max*60*60 )) #hours
			fi
			while [[ $pid_transfer_status -eq 1 ]]; do
				if [[ $(date +%s) -gt $quittime ]]; then
					echo -e "\e[00;31mERROR: FTP transfer failed after max retries($retry_download_max hours)!\e[00m"
					echo "Program has ended"
					kill -9 $pid_f_process &> /dev/null
					kill -9 $(sed -n '4p' "$lockfile") &> /dev/null
					cleanup session
					cleanup end
					exit 0
					break
				fi
				echo -e "\e[00;31mERROR: FTP transfer failed for some reason!\e[00m"
				echo "INFO: Keep trying until $(date --date=@$quittime)"
				# ok done, kill processbar
				kill -9 $pid_f_process &> /dev/null
				kill -9 $(sed -n '4p' "$lockfile") &> /dev/null
				scriptend=$(date +%s)
				echo -e "\e[00;31mTransfer terminated: $(date '+%d/%m/%y-%a-%H:%M:%S')\e[00m"
				waittime=$(($retry_download*60))
				echo "INFO: Pausing session and trying again $retry_download"mins" later"
				sed "3s#.*#***************************	FTP INFO: DOWNLOAD POSTPONED! Trying again in "$retry_download"mins#" -i $logfile
				sleep $waittime
				# restart transfer
					scriptstart=$(date +%s)
					scriptstart2=$(date '+%d/%m/%y-%a-%H:%M:%S')
					echo -e "\e[00;32mTransfer started: $scriptstart2\e[00m"
					ftp_processbar $retry_option &> /dev/null &
					pid_f_process=$!
					sed "3c $pid_f_process" -i "$lockfile"
					$lftp -f "$ftptransfere_file" &> /dev/null &
					pid_transfer=$!
					sed "2c $pid_transfer" -i "$lockfile"
					wait $pid_transfer
			done
			#remove processbar processes
			kill -9 $pid_f_process &> /dev/null
			kill -9 $(sed -n '4p' $lockfile) &> /dev/null
			#confirm that transfer has been successfull
				if [[ $confirm_transfer == "true" ]]; then
					echo -e "\e[00;31mINFO: Confirming that everything has been transfered, please wait...\e[00m"
					ftp_transfere_check main
				fi
	else
		echo -e "\e[00;31mTESTMODE: LFTP-transfer NOT STARTED\e[00m"
		echo "Would transfer:"
		i=0
		for n in "${changed_name[@]}"; do
			echo "${filepath[$i]} --> $ftpincomplete and move that to $ftpcomplete${orig_name[$i]}"
			let i++
		done
	fi
	}
}

function ftp_transfere_check { #confirm that everything has been transfered
case "$1" in
	"main" )
		if [[ -n $retry_count ]]; then #first time set variables
			retry_count=0
			ftp_transfere_check_file="$scriptdir/run/$username.ftptransfercheckfile"
			temp_check="$scriptdir/run/$username.tempcheckfile"
			final_check="$scriptdir/run/$username.finalcheckfile"
		fi
		while [[ $final_check_size -lt $directorysize ]]; do
			cat "$ftplogin_file" >> "$ftp_transfere_check_file"	
			echo "du -s \"$ftpincomplete${changed_name[$i]}\" > ~/../..$temp_check " >> "$ftp_transfere_check_file"
			echo "du -s \"$ftpcomplete${changed_name[$i]}\" > ~/../..$final_check " >> "$ftp_transfere_check_file"
			echo "exit" >> "$ftp_transfere_check_file"
			$lftp -f "$ftp_transfere_check_file" &> /dev/null
			if [[ -f "$ftp_transfere_check_file" ]]; then rm "$ftp_transfere_check_file"; fi
			if [[ -a $final_check ]]; then
				echo "INFO: Item found in complete directory. Attempt $retry_count"
				ftp_transfere_check complete
			elif [[ -a $temp_check ]]; then
				echo "INFO: Item not found in incomplete directory. Attempt $retry_count"
				ftp_transfere_check incomplete
			fi
		done
		if [[ -f "$temp_check" ]]; then rm "$temp_check"; fi
		if [[ -f "$final_check" ]]; then rm "$final_check"; fi
	;;
	"incomplete" )
		echo "INFO: Complete directory is found too small, $temp_check_size. Should be $directorysize Trying to retransfer..."
		retry_option="incomplete"
		ftp_transfere
		# check file size and retransfer
		rm "$temp_check"
		if [[ $retry_count -eq $retries ]]; then
			echo -e "\e[00;31mERROR: Full transfer unsuccessfull\e[00m"
			break
		fi
		let retry_count++
	;;
	"complete" )
		final_check_size=$(cat "$final_check" | awk '{print $1}')
		echo "INFO: Complete directory is found too small, $final_check_size bytes. Should be $directorysize bytes Trying to retransfer..."
		retry_option="complete"
		ftp_transfere #retry transfer
		rm "$final_check"
		if [[ $retry_count -eq $retries ]]; then
			echo -e "\e[00;31mERROR: Full transfer unsuccessfull\e[00m"
			break
		fi
		let retry_count++
	;;
esac
}

function ftp_processbar { #Showing how download is proceding
	if [[ "$processbar" == "true" ]]; then
		if [[ $test_mode != "true" ]]; then
			sleep 5 #wait for transfer to start
			loop="true"
			if [[ $transferetype == "downftp" ]]; then
				if [[ -z $1 ]] || [[ $retry_option == "incomplete" ]]; then
					local transfered_size="du -s \"$ftpincomplete$changed_name\" > \"$proccess_bar_file\""
				elif [[ $retry_option == "complete" ]]; then
					local transfered_size="du -s \"$ftpcomplete$changed_name\" > \"$proccess_bar_file\""
				fi
			elif [[ $transferetype == "upftp" ]]; then
				#Create configfile for lftp processbar
				cat "$ftplogin_file" >> "$ftptransfere_processbar"
				# ~ is /home/USER/
				if [[ -z $1 ]] || [[ $retry_option == "incomplete" ]]; then
					echo "du -s \"$ftpincomplete$changed_name\" > ~/../..$proccess_bar_file" >> "$ftptransfere_processbar"
				elif [[ $retry_option == "complete" ]]; then
					echo "du -s \"$ftpcomplete$changed_name\" > ~/../..$proccess_bar_file" >> "$ftptransfere_processbar"
				fi
				echo "quit" >> "$ftptransfere_processbar"
			fi
			{ #run processbar loop
			while [[ "$loop" = "true" ]]; do
				if [[ ${#changed_name[@]} -gt 2 ]]; then
					echo "INFO: Progress not possible due to a lot of changing files"
					sed "5s#.*#***************************	Transfering: $orig_name - x% in x at x MB/s. ETA: x  #" -i $logfile
					break
				else
					if [[ $transferetype == "downftp" ]]; then
						eval $transfered_size
					elif [[ $transferetype == "upftp" ]]; then
						$lftp -f "$ftptransfere_processbar" &> /dev/null &
						pid_process=$!
						sed "4c $pid_process" -i $lockfile
						wait $pid_process
					fi
				fi
				if [[ $? -eq 0 ]]; then #require feedback from server!
					# checks tranfered size and converts til human readable sizes
					if [[ -a $proccess_bar_file ]]; then
						transfered=$(cat $proccess_bar_file | awk '{print $1}')
						diff=$(( $(date +%s) - $scriptstart ))
						timediff=$(printf '%02dh:%02dm:%02ds' "$(($diff/(60*60)))" "$((($diff/60)%60))" "$(($diff%60))")		
						# if not empty calculate values, if empty we know nothing
						if [[ "$transfered" -ge "1" ]] && [[ "$transfered" =~ ^[0-9]+$ ]]; then
								transfered=$(echo "scale=2; "$transfered" / (1024)" | bc)
								procentage=$(echo "scale=4; "$transfered" / "$size" * 100" | bc)
								procentage=$(echo $procentage | sed 's/\(.*\)../\1/')
								speed=$(echo "scale=2; ( $transfered ) / $diff" | bc)
								eta=$(echo "( $size - $transfered ) / $speed" | bc)
								etatime=$(printf '%02dh:%02dm:%02ds' "$(($eta/(60*60)))" "$((($eta/60)%60))" "$(($eta%60))")
							else
								speed="x"
								procentage="0"
								etatime="Unknown"
						fi
						#update file and output the current line
						sed "5s#.*#***************************	Transfering: $orig_name - $procentage% in $timediff at $speed MB/s. ETA: $etatime  #" -i $logfile
						echo -ne  "$procentage% is done in $timediff at $speed MB/s. ETA: $etatime\r"
					fi
				fi
				sleep $sleeptime
			done
			}
			#new line
			echo -ne '\n'
		else
			echo -e "\e[00;31mTESTMODE: LFTP-processbar NOT STARTED\e[00m"
		fi
	fi
}

function logrotate {
	if [[ $test_mode != "true" ]]; then
			diff=$(( $scriptend - $scriptstart ))
			timediff=$(printf '%02dh:%02dm:%02ds' "$(($diff/(60*60)))" "$((($diff/60)%60))" "$(($diff%60))")
			speed=$(echo "scale=2; $size / $diff" | bc)
			#Adds new info to 7th line, below everyhting statis
			sed "7i $scriptstart2 - $source - $orig_name, $size\MB, $timediff, $speed\MB/s" -i $logfile
			lognumber=$((7 + $lognumber ))
			#Add text to old file
			if [[ $logrotate == "true" ]]; then
				if [[ -n $(sed -n $lognumber,'$p' $logfile) ]]; then
					sed -n $lognumber,'$p' $logfile >> $oldlogfile
				fi
			fi
			#Remove text from old file
			if [ $lognumber -ne 0 ]; then
				sed $lognumber,'$d' -i $logfile
			fi
			totaldl=$(awk 'BEGIN{FS="|";OFS=" "}NR==2{print $1}' $logfile | cut -d' ' -f2)
			totaldl=${totaldl%MB}
			if [[ -z $totaldl ]]; then
				totaldl="0"
			fi
			totaldl=${totaldl%MB}
			totaldl=$(echo "$totaldl + $size" | bc)
			totalrls=$(awk 'BEGIN{FS="|";OFS=" "}NR==2{print $1}' $logfile | cut -d' ' -f4)
			totalrls=$(echo "$totalrls + 1" | bc)
			totaldltime=$(awk 'BEGIN{FS="|";OFS=" "}NR==2{print $1}' $logfile | cut -d' ' -f7)
			totaldltime_seconds=$(awk 'BEGIN{split("'$totaldltime'",a,":"); print a[1]*(60*60*24)+a[2]*(60*60)+a[3]*60+a[4];}')
			totaldltime=$(echo "$totaldltime_seconds + $diff" | bc)
			totaldltime=$(printf '%02dd:%02dh:%02dm:%02ds' "$(($totaldltime/(60*60*24)))" "$(($totaldltime/(60*60)%24))" "$((($totaldltime/60)%60))" "$(($totaldltime%60))")

			sed "1s#.*#***************************	FTP AUTODOWNLOAD SCRIPT FOR FLEXGET - $s_version#" -i $logfile
			sed "2s#.*#***************************	STATS: "$totaldl"MB in $totalrls releases in $totaldltime#" -i $logfile
			sed "4s#.*#***************************	LASTDL: $(date) - "$orig_name" at "$speed"MB/s#" -i $logfile
			sed "5s#.*#***************************	#" -i $logfile
		else
			echo -e "\e[00;31mTESTMODE: LOGGING NOT STARTED\e[00m"
	fi
}

function create_log_file {
	if [ ! -e "$logfile" ]; then
		echo "INFO: First time used - logfile is created"
		echo "***************************	FTP AUTODOWNLOAD SCRIPT FOR FLEXGET - $s_version" >> $logfile
		echo "***************************	STATS: 0MB in 0 releases in 00d:00h:00m:00s" >> $logfile
		if [[ $ftpsizemanagement == "true" ]]; then
			echo "***************************	FTP INFO: 0/"$totalmb"MB (Free "$freemb"MB)" >> $logfile
		else
			echo "***************************	FTP INFO: not enabled" >> $logfile
		fi
		echo "***************************	LASTDL: nothing" >> $logfile
		echo "***************************	" >> $logfile
		echo "**********************************************************************************************************************************" >> $logfile
		echo "" >> $logfile
		else
			echo "INFO: Logfile: \"$logfile\""
	fi
}

function loadConfig {
	# load config for default
	if [[ -z "$user" ]] && [[ -f "$scriptdir/users/default/config" ]]; then
		echo "INFO: Loading default config"
		username="default"
		config_name="$scriptdir/users/default/config"
	# load config for <USER>
	elif [[ -n "$user" ]] && [[ -f "$scriptdir/users/$user/config" ]]; then
		echo "INFO: Loading config: \"$user\""
		source "$scriptdir/users/$user/config"
		username="$user"
	else
		if [[ -z "$user" ]] && [[ ! -f "$scriptdir/users/default/config" ]]; then
			echo -e "\e[00;31mERROR: No config found for default\e[00m"
		elif [[ -n "$user" ]]; then
			echo -e "\e[00;31mERROR: No config found for user=$user\e[00m"
		fi
		echo -e "\e[00;31mYou may want to have a look on help, --help\e[00m"
		exit 1
	fi
	# confirm that config is most recent version
	if [[ $config_version -lt "1" ]]; then
		echo -e "\e[00;31mERROR: Config is out-dated, please update it. See --help for more info!\e[00m"
		cleanup session
		cleanup end
		exit 0
	fi

	#load paths to everything
	setup
	check_setup
	create_log_file
}

function check_setup {
	# Add trailing slash if it is missing
	if [[ "$ftpincomplete" != */ ]]; then
		ftpincomplete="$ftpincomplete/"
	fi
	if [[ "$ftpcomplete" != */ ]]; then
		ftpcomplete="$ftpcomplete/"
	fi
}

function lockfile {
	case "$1" in
		"new" )
			echo "INFO: Writing lockfile: \"$lockfile\""
			if [[ -f "$lockfile" ]] && [[ $force != "true" ]]; then
				#The file exists, find PID, transfere, confirm it still is running
				mypid_script=$(sed -n 1p "$lockfile")
				mypid=$(sed -n 2p "$lockfile")
				alreadyinprogres=$(sed -n 3p "$lockfile")
				kill -0 $mypid_script
				if [[ $? -eq 1 ]]; then
					#Process is not running, continue
					echo "INFO: No lockfile detected"
					rm "$lockfile"
				else
					echo -e "\e[00;31mERROR: The user $user is running something\e[00m"
					echo "       The script running is: $mypid_script"
					echo "       The transfere is: "$alreadyinprogres""
					echo "       If that is wrong remove you need to remove $lockfile"
					echo "       Wait for it to end, or kill it: kill -9 pidID"
					echo ""
					if [[ $queue == "true" ]]; then
							queue add end
					else
						exit 1
					fi
				fi
			fi
			#allocate pids
			echo >> "$lockfile"
			echo >> "$lockfile"
			echo >> "$lockfile"
			echo >> "$lockfile"
			sed "1c $BASHPID" -i "$lockfile"
			echo "INFO: Running at pid=$BASHPID"
		;;
	esac
}

function load_help {
	if [[ -e "$scriptdir/dependencies/help.sh" ]]; then
		source "$scriptdir/dependencies/help.sh"
	else
		echo -e "\e[00;31mError: /dependencies/help.sh is\n needed in order for this program to work\e[00m";
		exit 1
	fi
}

function main {
#setting paths
filepath="$1"
orig_path="$filepath"
orig_name=$(basename "$filepath")
# Use change_name in script as it might change later on (largefile)
changed_name="$orig_name"
tempdir="$scriptdir/run/$username-temp-$orig_name/"

echo "INFO: Preparing transfere of \"$filepath\""
echo "INFO: Lunched from \"$source\""

#add to queue file, to get Id initialized
queue add

echo "INFO: $parallel Simultaneous transferes"

#Checking transferesize
get_size "$filepath" "exclude_array[@]"

#Execute preexternal command
if [[ -n $exec_pre ]]; then
	if [[ $test_mode != "true" ]]; then
			echo "INFO: Executing external command: \"$exec\" "
			eval $exec_pre
	else
		echo -e "\e[00;31mTESTMODE: Would execute external command: \"$exec\"\e[00m"
	fi
fi

#Prepare login
source "$scriptdir/dependencies/ftp_login.sh" && ftp_login

#confirm server is online
if [[ $confirm_online == "true" ]]; then
	source "$scriptdir/dependencies/ftp_online_test.sh" && online_test
fi


#Check if enough free space on ftp
if [[ "$ftpsizemanagement" == "true" ]]; then
	source "$scriptdir/dependencies/ftp_size_management.sh" && ftp_sizemanagement check
fi

#Is largest file too large
if [[ "$split_files" == "true" ]] && [[ "$video_file_only" != "true" ]]; then
	if [[ $transferetype == "upftp" ]]; then
		source "$scriptdir/dependencies/largefile.sh" && largefile "$filepath" "exclude_array[@]"
	elif [[ $transferetype == "downftp" ]]; then
		echo -e "\e[00;33mERROR: split_files is not supported in mode=$transferetype. Continuing without ...\e[00m"
	fi
fi

# Try to only send videofile
if [[ "$video_file_only" == "true" ]] && [[ "$split_files" != "true" ]]; then
	if [[ $transferetype == "upftp" ]]; then
		source "$scriptdir/plugins/videofile.sh" && videoFile
	elif [[ $transferetype == "downftp" ]]; then
		echo -e "\e[00;33mERROR: video_file_only is not supported in mode=$transferetype. Continuing without ...\e[00m"
	fi
fi

# Try to sort files
if [[ "$sort" == "true" ]]; then
	source "$scriptdir/dependencies/sorting.sh" && sortFiles "$sortto"
fi

# Remove item from flexget config
if [[ -n "$feed_name" ]]; then
	source "$scriptdir/plugins/flexget.sh" && flexget_feed
fi

#Transfere happens here
scriptstart=$(date +%s)
scriptstart2=$(date '+%d/%m/%y-%a-%H:%M:%S')
echo -e "\e[00;37mINFO: \e[00;32mTransfer started: $scriptstart2\e[00m"

# Delay transfer if needed
delay

# Transfer files
ftp_transfere

scriptend=$(date +%s)
echo -e "\e[00;37mINFO: \e[00;32mTransfer ended: $(date '+%d/%m/%y-%a-%H:%M:%S')\e[00m"

# Checking for remaining space
if [[ "$ftpsizemanagement" == "true" ]]; then
	ftp_sizemanagement info # already loaded previously
fi


# Update logfile
logrotate

# Clean up current session
cleanup session

echo "INFO: Finished \"$orig_name\", "$size"MB, in $timediff, "$speed"MB/s"

#send push notification
if [[ -n $push_user ]]; then
	if [[ $test_mode != "true" ]]; then
		source $scriptdir/plugins/pushover.sh "NEW STUFF: $orig_name, "$size"MB, in $timediff, "$speed"MB/s"
	else
		echo -e "\e[00;31mTESTMODE: Would send notification \"NEW STUFF: $orig_name, "$size"MB, in $timediff, "$speed"MB/s\" to token=$push_token and user=$push_user \e[00m"
	fi
fi
echo

#Execute external command
if [[ -n $exec_post ]]; then
	if [[ $test_mode != "true" ]]; then
		if [[ $allow_background == "true" ]]; then
			echo "INFO: Executing external command(In background): \"$exec\" "
			eval $exec &
		else
			echo "INFO: Executing external command: \"$exec\" "
			eval $exec
		fi
	else
		echo -e "\e[00;31mTESTMODE: Would execute external command: \"$exec\"\e[00m"
	fi
fi

# Remove finished one
queue remove
# Run queue
queue run
}

################################################### CODE BELOW #######################################################
{ #initiation
#Look for which options has been used
if (($# < 1 )); then echo; echo -e "\e[00;31mERROR: No option specified\e[00m"; echo "See --help for more information"; echo ""; exit 0; fi
while :
do
	case "$1" in
		--help | -h ) option="help"; shift;;
		--path=* ) filepath="${1#--path=}"; shift;;
		--feed=* ) feed="${1#--feed=}"; shift;;
		--user=* ) user="${1#--user=}"; shift;;
		--exec_post=* ) exec_post="${1#--exec_post=}"; shift;;
		--exec_pre=* ) exec_pre="${1#--exec_pre=}"; shift;;
		--delay=* ) date_time="${1#--delay=}"; shift;;
		--force | -f ) force=true; shift;;
		--source=* ) source="${1#--source=}"; shift;;
		--sort=* ) sortto="${1#--sort=}"; shift;;
		--example ) load_help; show_example; exit 0;;
		--freespace ) ftp_sizemanagement info; cleanup session; exit 0;;
		--test ) test_mode="true"; echo "INFO: Running in TESTMODE, no changes are made!"; shift;;
		-* ) echo -e "\e[00;31mInvalid option: $@\e[00m"; echo "See --help for more information"; echo ""; exit 1;;
		* ) break ;;
		--) shift; break;;
	esac
done

#Load dependencies
source "$scriptdir/dependencies/setup.sh" && setup

#Check wether we have an external config, user config or no config at all
loadConfig

case "$option" in
	"help" ) # Write out help
		load_help; show_help; show_example; exit 0
	;;
	* ) # main program
		if [[ -d "$filepath" ]] || [[ -f "$filepath" ]] && [[ -z $(find "$filepath" -type f) ]]; then
			# make sure that path is real and contains something, else exit
			# if not used, do nothing!
			echo -e "\e[00;31mERROR: Option --path is required with existing path and has to contain file(s).\n See --help for more info!\e[00m"
			echo
			cleanup session
			cleanup end
			exit 1
		fi

		# Looking for lockfile, create if not present, and if something new is added, add to queue if something
		# running. If nothing is running continue
		lockfile "new"

		if [[ -z "$filepath" ]]; then
			# if --path is not used, try and run queue
			queue run
		fi

		# OK nothing running and --path is real, lets continue
		# fix spaces: "/This\ is\ a\ path"
		# Note: The use of normal backslashes is NOT supported
		filepath="$(echo "$filepath" | sed 's/\\./ /g')"
		# Set source manually if it ins't set
		if [[ -z $source ]]; then
				source="CONSOLE"
		fi

		#start program
		main "$filepath"
	;;
esac
}
