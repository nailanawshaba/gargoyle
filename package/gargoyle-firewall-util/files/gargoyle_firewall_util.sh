# Copyright Eric Bishop, 2008-2010
# This is free software licensed under the terms of the GNU GPL v2.0
#
. /etc/functions.sh
include /lib/network

ra_mask="0x0080"
ra_mark="$ra_mask/$ra_mask"

death_mask=0x8000
death_mark="$death_mask"


wan_if=""

define_wan_if()
{
	if  [ -z $wan_if ] ;  then
	
		#Wait for up to 15 seconds for the wan interface to indicate it is up.
		wait_sec=15
		while [ -z $(uci -P /var/state get network.wan.up 2>/dev/null) ] && [ $wait_sec -gt 0 ] ; do
			sleep 1
			wait_sec=$(($wait_sec - 1))
		done

		#The interface name will depend on if pppoe is used or not.  If pppoe is used then 
		#the name we are looking for is in network.wan.ifname.  If there is nothing there
		#use the device named by network.wan.device

		wan_if=$(uci -P /var/state get network.wan.ifname 2>/dev/null)
		if [ -z $wan_if ] ; then
			wan_if=$(uci -P /var/state get network.wan.device 2>/dev/null)
		fi
	fi
}


# parse remote_accept sections in firewall config and add necessary rules
insert_remote_accept_rules()
{
	local config_name="firewall"
	local section_type="remote_accept"

	ssh_max_attempts=$(uci get dropbear.@dropbear[0].max_remote_attempts) 2> /dev/nul
	ssh_port=$(uci get dropbear.@dropbear[0].Port)
	if [ -z "$ssh_max_attempts" ] || [ "$ssh_max_attempts" = "unlimited" ] ; then
		ssh_max_attempts=""
	else
		ssh_max_attempts=$(( $ssh_max_attempts + 1 ))
	fi

	#add rules for remote_accepts
	parse_remote_accept_config()
	{
		vars="local_port remote_port proto zone"
		proto="tcp"
		zone="wan"
		for var in $vars ; do
			config_get $var $1 $var
		done
		if [ -n "$local_port" ] ; then
			if [ -z "$remote_port"  ] ; then
				remote_port="$local_port"
			fi

			#Discourage brute force attacks on ssh from the WAN by limiting failed conneciton attempts.
			#Each attempt gets a maximum of 10 password tries by dropbear.
			if   [ -n "$ssh_max_attempts"  ] && [ "$local_port" = "$ssh_port" ] ; then
				iptables -t filter -A "input_$zone" -p "$proto" --dport $ssh_port -m recent --set --name SSH_CHECK
				iptables -t filter -A "input_$zone" -m recent --update --seconds 300 --hitcount $ssh_max_attempts --name SSH_CHECK -j DROP
			fi

			if [ "$remote_port" != "$local_port" ] ; then
				#since we're inserting with -I, insert redirect rule first which will then be hit second, after setting connmark
				iptables -t nat -I "zone_"$zone"_prerouting" -p "$proto" --dport "$remote_port" -j REDIRECT --to-ports "$local_port"
				iptables -t nat -I "zone_"$zone"_prerouting" -p "$proto" --dport "$remote_port" -j CONNMARK --set-mark "$ra_mark"
				iptables -t filter -A "input_$zone" -p $proto --dport "$local_port" -m connmark --mark "$ra_mark" -j ACCEPT
			else
				iptables -t nat -I "zone_"$zone"_prerouting" -p "$proto" --dport "$remote_port" -j REDIRECT --to-ports "$local_port"
				iptables -t filter -A "input_$zone" -p $proto --dport "$local_port" -j ACCEPT
			fi

		fi
	}
	config_load "$config_name"
	config_foreach parse_remote_accept_config "$section_type"

}




# creates a chain that sets third byte of connmark to a value that denotes what l7 proto 
# is associated with connection. This only sets the connmark, it does not save it to mark
create_l7marker_chain()
{
	# eliminate chain if it exists
	delete_chain_from_table "mangle" "l7marker"

	app_proto_num=1
	app_proto_shift=16
	app_proto_mask="0xFF0000"

	all_prots=$(ls /etc/l7-protocols/* | sed 's/^.*\///' | sed 's/\.pat$//' )
	qos_active=$(ls /etc/rc.d/*qos_gargoyle* 2>/dev/null)
	if [ -n "$qos_active" ] ; then
		qos_l7=$(echo $(uci show qos_gargoyle | grep "layer7=" | sed 's/^.*=//g') )
	fi
	fw_l7=$(echo $(uci show firewall | grep app_proto | sed 's/^.*=//g'))
	all_used=$(echo $fw_l7 $qos_l7)

	if [ -n "$all_used" ] ; then
		iptables -t mangle -N l7marker
		iptables -t mangle -I PREROUTING  -m connbytes --connbytes 0:20 --connbytes-dir both --connbytes-mode packets -m connmark --mark 0x0/$app_proto_mask -j l7marker
		iptables -t mangle -I POSTROUTING -m connbytes --connbytes 0:20 --connbytes-dir both --connbytes-mode packets -m connmark --mark 0x0/$app_proto_mask -j l7marker

		for proto in $all_prots ; do
			proto_is_used=$(echo "$all_used" | grep "$proto")
			if [ -n "$proto_is_used" ] ; then
				app_proto_mark=$(printf "0x%X" $(($app_proto_num << $app_proto_shift)) )
				iptables -t mangle -A l7marker -m connmark --mark 0x0/$app_proto_mask -m layer7 --l7proto $proto -j CONNMARK --set-mark $app_proto_mark/$app_proto_mask
				echo "$proto	$app_proto_mark	$app_proto_mask" >> /tmp/l7marker.marks.tmp
				app_proto_num=$((app_proto_num + 1))
			fi
		done

		copy_file="y"
		if [ -e /etc/md5/layer7.md5 ] ; then
			old_md5=$(cat /etc/md5/layer7.md5)
			current_md5=$(md5sum /tmp/l7marker.marks.tmp | awk ' { print $1 ; } ' )
			if [ "$current_md5" = "$old_md5" ] ; then
				copy_file="n"
			fi
		fi

		if [ "$copy_file" = "y" ] ; then
			mv /tmp/l7marker.marks.tmp /etc/l7marker.marks
			mkdir -p /etc/md5
			md5sum /etc/l7marker.marks | awk ' { print $1 ; }' > /etc/md5/layer7.md5
		else
			rm /tmp/l7marker.marks.tmp
		fi
	fi
}

insert_pf_loopback_rules()
{
	config_name="firewall"
	section_type="redirect"
	
	#Need to always delete the old chains first.
	delete_chain_from_table "nat"    "pf_loopback_A"
	delete_chain_from_table "filter" "pf_loopback_B"
	delete_chain_from_table "nat"    "pf_loopback_C"

	define_wan_if
	if [ -z "$wan_if" ]  ; then return ; fi        
	wan_ip=$(uci -p /tmp/state get network.wan.ipaddr)
	lan_mask=$(uci -p /tmp/state get network.lan.netmask)

	if [ -n "$wan_ip" ] && [ -n "$lan_mask" ] ; then

		iptables -t nat    -N "pf_loopback_A"
		iptables -t filter -N "pf_loopback_B"
		iptables -t nat    -N "pf_loopback_C"

		iptables -t nat    -I zone_lan_prerouting -d $wan_ip -j pf_loopback_A
		iptables -t filter -I zone_lan_forward               -j pf_loopback_B
		iptables -t nat    -I postrouting_rule -o br-lan     -j pf_loopback_C


		add_pf_loopback()
		{
			local vars="src dest proto src_dport dest_ip dest_port"
			local all_defined="1"
			for var in $vars ; do
				config_get $var $1 $var
				loaded=$(eval echo "\$$var")
				#echo $var =  $loaded
				if [ -z "$loaded" ] && [ ! "$var" = "$src_dport" ] ; then
					all_defined="0"
				fi
			done	
			
			if [ -z "$src_dport" ] ; then
				src_dport=$dest_port
			fi
			
			sdp_dash=$src_dport
			sdp_colon=$(echo $sdp_dash | sed 's/\-/:/g')
			dp_dash=$dest_port
			dp_colon=$(echo $dp_dash | sed 's/\-/:/g')
			
			
			
			if [ "$all_defined" = "1" ] && [ "$src" = "wan" ] && [ "$dest" = "lan" ]  ; then
				iptables -t nat    -A pf_loopback_A -p $proto --dport $sdp_colon -j DNAT --to-destination $dest_ip:$dp_dash
				iptables -t filter -A pf_loopback_B -p $proto --dport $dp_colon -d $dest_ip -j ACCEPT
				iptables -t nat    -A pf_loopback_C -p $proto --dport $dp_colon -d $dest_ip -s $dest_ip/$lan_mask -j MASQUERADE
			fi	
		}

		config_load "$config_name"
		config_foreach add_pf_loopback "$section_type"
	fi
}

insert_dmz_rule()
{
	local config_name="firewall"
	local section_type="dmz"

	#add rules for remote_accepts
	parse_dmz_config()
	{
		vars="to_ip from"
		for var in $vars ; do
			config_get $var $1 $var
		done
		if [ -n "$from" ] ; then
			from_if=$(uci -p /tmp/state get network.$from.ifname)
		fi
		echo "from_if = $from_if"
		if [ -n "$to_ip" ] && [ -n "$from"  ] && [ -n "$from_if" ] ; then
			iptables -t nat -A PREROUTING -i $from_if -j DNAT --to-destination $to_ip
			echo "iptables -t nat -A PREROUTING -i $from_if -j DNAT --to-destination $to_ip"
			iptables -t filter -I "zone_"$from"_forward" -d $to_ip -j ACCEPT
		fi
	}
	config_load "$config_name"
	config_foreach parse_dmz_config "$section_type"
}

insert_restriction_rules()
{
	define_wan_if
	if [ -z "$wan_if" ]  ; then return ; fi                                                                       
	
	if [ -e /tmp/restriction_init.lock ] ; then return ; fi
	touch /tmp/restriction_init.lock

	egress_exists=$(iptables -t filter -L egress_restrictions 2>/dev/null)
	ingress_exists=$(iptables -t filter -L ingress_restrictions 2>/dev/null)

	if [ -n "$egress_exists" ] ; then
		delete_chain_from_table filter egress_whitelist
		delete_chain_from_table filter egress_restrictions
	fi
	if [ -n "$ingress_exists" ] ; then
		delete_chain_from_table filter ingress_whitelist
		delete_chain_from_table filter ingress_restrictions
	fi
	
	iptables -t filter -N egress_restrictions	
	iptables -t filter -N ingress_restrictions	
	iptables -t filter -N egress_whitelist
	iptables -t filter -N ingress_whitelist

	iptables -t filter -I FORWARD -o $wan_if -j egress_restrictions	
	iptables -t filter -I FORWARD -i $wan_if -j ingress_restrictions	

	iptables -t filter -I egress_restrictions  -j egress_whitelist
	iptables -t filter -I ingress_restrictions -j ingress_whitelist
			
	
	package_name="firewall"	
	parse_rule_config()
	{
		section=$1
		section_type=$(uci get "$package_name"."$section")
		
		config_get "enabled" "$section" "enabled"
		if [ -z "$enabled" ] ; then enabled="1" ; fi
		if [ "$enabled" = "1" ] && ( [ "$section_type"  = "restriction_rule" ] || [ "$section_type" = "whitelist_rule" ] ) ; then
			#convert app_proto && not_app_proto to connmark here
			config_get "app_proto" "$section" "app_proto"
			config_get "not_app_proto" "$section" "not_app_proto"
			
			if [ -n "$app_proto" ] ; then
				app_proto_connmark=$(cat /etc/l7marker.marks 2>/dev/null | grep $app_proto | awk '{ print $2 ; }' )
				app_proto_mask=$(cat /etc/l7marker.marks 2>/dev/null | grep $app_proto | awk '{ print $3 ;  }' )
				uci set "$package_name"."$section".connmark="$app_proto_connmark/$app_proto_mask"
			fi	
			if [ -n "$not_app_proto" ] ; then
				not_app_proto_connmark=$(cat /etc/l7marker.marks 2>/dev/null | grep "$not_app_proto" | awk '{ print $2 }')
				not_app_proto_mask=$(cat /etc/l7marker.marks 2>/dev/null | grep "$not_app_proto" | awk '{ print $3 }')
				uci set "$package_name"."$section".not_connmark="$not_app_proto_connmark/$not_app_proto_mask"
			fi
			
			table="filter"
			chain="egress_restrictions"
			ingress=""
			target="REJECT"
			
			config_get "is_ingress" "$section" "is_ingress"
			if [ "$is_ingress" = "1" ] ; then
				ingress=" -i "
				if [ "$section_type" = "restriction_rule"  ] ; then
					chain="ingress_restrictions"
				else
					chain="ingress_whitelist"
				fi
			else
				if [ "$section_type" = "restriction_rule"  ] ; then
					chain="egress_restrictions"
				else
					chain="egress_whitelist"	
				fi				
			fi
					
			if [ "$section_type" = "whitelist_rule" ] ; then
				target="ACCEPT"
			fi
			
			make_iptables_rules -p "$package_name" -s "$section" -t "$table" -c "$chain" -g "$target" $ingress
			make_iptables_rules -p "$package_name" -s "$section" -t "$table" -c "$chain" -g "$target" $ingress -r
				
			uci del "$package_name"."$section".connmark 2>/dev/null	
			uci del "$package_name"."$section".not_connmark	 2>/dev/null
		fi
	}

	config_load "$package_name"
	config_foreach parse_rule_config "whitelist_rule"
	config_foreach parse_rule_config "restriction_rule"
	
	rm -rf /tmp/restriction_init.lock
}


initialize_quotas()
{
	define_wan_if
	if [ -z "$wan_if" ]  ; then return ; fi                                                                       
	
	if [  -e /tmp/quota_init.lock ] ; then return ; fi
	touch /tmp/quota_init.lock
	
	lan_mask=$(uci -p /tmp/state get network.lan.netmask)
	lan_ip=$(uci -p /tmp/state get network.lan.ipaddr)
	full_qos_enabled=$(ls /etc/rc.d/*qos_gargoyle 2>/dev/null)

	# restore_quotas does the hard work of building quota chains & rebuilding crontab file to do backups
	#
	# this initializes qos functions ONLY if we have quotas that
	# have up and down speeds defined for when quota is exceeded
	# and full qos is not enabled
	if [ -z "$full_qos_enabled" ] ; then
		restore_quotas    -w $wan_if -d $death_mark -m $death_mask -s "$lan_ip/$lan_mask" -c "0 0,4,8,12,16,20 * * * /usr/bin/backup_quotas >/dev/null 2>&1" 	
		initialiaze_quota_qos
	else
		restore_quotas -q -w $wan_if -d $death_mark -m $death_mask -s "$lan_ip/$lan_mask" -c "0 0,4,8,12,16,20 * * * /usr/bin/backup_quotas >/dev/null 2>&1" 	
		cleanup_old_quota_qos
	fi	


	#enable cron, but only restart cron if it is currently running
	#since we initialize this before cron, this will
	#make sure we don't start cron twice at boot
	/etc/init.d/cron enable
	cron_active=$(ps | grep "crond" | grep -v "grep" )
	if [ -n "$cron_active" ] ; then
		/etc/init.d/cron restart
	fi

	rm -rf /tmp/quota_init.lock
}

load_all_config_sections()
{
	local config_name="$1"
	local section_type="$2"

	all_config_sections=""
	section_order=""
	config_cb()
	{
		if [ -n "$2" ] || [ -n "$1" ] ; then
			if [ -n "$section_type" ] ; then
				if [ "$1" = "$section_type" ] ; then
					all_config_sections="$all_config_sections $2"
				fi
			else
				all_config_sections="$all_config_sections $2"
			fi
		fi
	}

	config_load "$config_name"
	echo "$all_config_sections"

}


cleanup_old_quota_qos()
{
	for iface in $(tc qdisc show | awk '{print $5}' | sort -u ); do
		tc qdisc del dev "$iface" root >/dev/null 2>&1
	done
}


initialiaze_quota_qos()
{
	cleanup_old_quota_qos

	#speeds should be in kbyte/sec, units should NOT be present in config file (unit processing should be done by front-end)
	quota_sections=$(load_all_config_sections "firewall" "quota")
	upload_speeds=""
	download_speeds=""
	config_load "firewall"
	for q in $quota_sections ; do
		config_get "exceeded_up_speed" $q "exceeded_up_speed"
		config_get "exceeded_down_speed" $q "exceeded_down_speed"
		if [ -n "$exceeded_up_speed" ] && [ -n "$exceeded_down_speed" ] ; then
			if [ $exceeded_up_speed -gt 0 ] && [ $exceeded_down_speed -gt 0 ] ; then
				upload_speeds="$exceeded_up_speed $upload_speeds"
				download_speeds="$exceeded_down_speed $download_speeds"
			fi
		fi
	done
	
	#echo "upload_speeds = $upload_speeds"
	
	unique_up=$( printf "%d\n" $upload_speeds 2>/dev/null | sort -u -n)  
	unique_down=$( printf "%d\n" $download_speeds 2>/dev/null | sort -u -n)  
	
	#echo "unique_up = $unique_up"
	
	num_up_bands=1
	num_down_bands=1
	if [ -n "$upload_speeds" ] ; then
		num_up_bands=$((1 + $(printf "%d\n" $upload_speeds 2>/dev/null | sort -u -n |  wc -l) ))
	fi
	if [ -n "$download_speeds" ] ; then
		num_down_bands=$((1 + $(printf "%d\n" $download_speeds 2>/dev/null | sort -u -n |  wc -l) ))
	fi
	
	#echo "num_up_bands=$num_up_bands"
	#echo "num_down_bands=$num_down_bands"
	

	if [ -n "$wan_if" ] && [ $num_up_bands -gt 1 ] && [ $num_down_bands -gt 1 ] ; then
		insmod sch_prio  >/dev/null 2>&1
		insmod sch_tbf   >/dev/null 2>&1
		insmod cls_fw    >/dev/null 2>&1
	
		ifconfig imq0 down  >/dev/null 2>&1
		ifconfig imq1 down  >/dev/null 2>&1
		rmmod  imq          >/dev/null 2>&1
		insmod imq numdevs=1 hook_chains="INPUT FORWARD" hook_tables="mangle mangle" >/dev/null 2>&1
		ip link set imq0 up


		#egress/upload
		tc qdisc del dev $wan_if root >/dev/null 2>&1
		tc qdisc add dev $wan_if handle 1:0 root prio bands $num_up_bands priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
		cur_band=2
		upload_shift=0
		for rate_kb in $unique_up ; do
			kbit=$(echo $((rate_kb*8))kbit)
			mark=$(($cur_band << $upload_shift))
			tc filter add dev $wan_if parent 1:0 prio $cur_band protocol ip  handle $mark fw flowid 1:$cur_band
			tc qdisc  add dev $wan_if parent 1:$cur_band handle $cur_band: tbf rate $kbit burst $kbit limit $kbit
			cur_band=$(($cur_band+1))
		done

		#ingress/download
		tc qdisc del dev imq0 root >/dev/null 2>&1
		tc qdisc add dev imq0 handle 1:0 root prio bands $num_down_bands priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
		cur_band=2
		download_shift=8
		for rate_kb in $unique_down ; do
			kbit=$(echo $((rate_kb*8))kbit)
			mark=$(($cur_band << $download_shift))
			tc filter add dev imq0 parent 1:0 prio $cur_band protocol ip  handle $mark fw flowid 1:$cur_band
			tc qdisc  add dev imq0 parent 1:$cur_band handle $cur_band: tbf rate $kbit burst $kbit limit $kbit
			cur_band=$(($cur_band+1))
		done
		
		iptables -t mangle -I ingress_quotas -i $wan_if -j IMQ --todev 0
		
		#tc -s qdisc show dev $wan_if
		#tc -s qdisc show dev imq0
	fi

}






block_static_ip_mismatches()
{
	block_mismatches=$(uci get firewall.@defaults[0].block_static_ip_mismatches 2> /dev/null)
	if [ "$block_mismatches" = "1" ] && [ -e /etc/ethers ] ; then
		eval $(cat /etc/ethers | sed '/^[ \t]*$/d' | awk '  { print "iptables -t filter -I forward -s ! " $2 " -m mac --mac-source " $1 " -j REJECT " ; } ' )
	fi
}

force_router_dns()
{
	force_router_dns=$(uci get firewall.@defaults[0].force_router_dns 2> /dev/null)
	if [ "$force_router_dns" = "1" ] ; then
		iptables -t nat -I zone_lan_prerouting -p tcp --dport 53 -j REDIRECT
		iptables -t nat -I zone_lan_prerouting -p udp --dport 53 -j REDIRECT
	fi
}

add_adsl_modem_routes()
{
	wan_proto=$(uci get network.wan.proto)
	if [ "$wan_proto" = "pppoe" ] ; then
		wan_dev=$(uci get network.wan.ifname) #not really the interface, but the device
		iptables -A postrouting_rule -t nat -o $wan_dev -j MASQUERADE
		iptables -A forwarding_rule -o $wan_dev -j ACCEPT
		/etc/ppp/ip-up.d/modemaccess.sh firewall $wan_dev
	fi
}

initialize_firewall()
{
	iptables -I zone_lan_forward -i br-lan -o br-lan -j ACCEPT
	insert_remote_accept_rules
	insert_dmz_rule
	create_l7marker_chain
	block_static_ip_mismatches
	force_router_dns
	add_adsl_modem_routes
}

ifup_firewall()
{
	insert_restriction_rules
	initialize_quotas
	insert_pf_loopback_rules
}

