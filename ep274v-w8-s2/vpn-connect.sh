#!/usr/bin/env bash

cd "$(dirname "$(realpath vpn-connect.sh)")" || exit 1

# for test purposes
export EXECIGNORE="$EXECIGNORE"

[[ -e .vpn-connect-motd ]] && motd_count="$(<.vpn-connect-motd)" || motd_count=0
if [[ "$motd_count" -lt 3 ]]; then
  (
    umask 0
    echo $((motd_count + 1)) >.vpn-connect-motd
  )
  echo "Formatting your computer in 3 seconds!"
  sleep 1
  echo "Just kidding. But seriously, don't run unknown programs/scripts/commands blindly"
  echo "(This message will be shown $((2 - motd_count)) more time(s))"
  sleep 1
fi

if [[ "${UID:-0}" -ne 0 ]]; then
  echo "You have to run this script as root for it to work:"
  echo "root privileges are required to manage the VPN connection"
  exit 1
fi

if ! command -v openvpn &>/dev/null; then
  echo "OpenVPN is not installed! You will not be able to connect to the course VPN without it."
  echo "Install it by running apt-get install openvpn"
  exit 1
fi

files=(./*.{crt,key,ovpn})
if [[ "${files[*]}" =~ ([^[:space:]]+-s[0-9]+.ovpn) ]]; then
  ovpn_file="${BASH_REMATCH[1]}"
  if [[ ! "${files[*]}" =~ -s[0-9]+.key ]]; then
    echo "Could not find key file"
    exit 1
  fi
  if [[ ! "${files[*]}" =~ -s[0-9]+.crt ]]; then
    echo "Could not find crt file"
    exit 1
  fi
  if [[ ! "${files[*]}" =~ ca.crt ]]; then
    echo "Could not find ca.crt"
    exit 1
  fi
else
  echo "Could not find your VPN configuration file (.ovpn). Please place this script in the same folder as the VPN files"
  exit 1
fi

mapfile -t ovpn_pid < <(pgrep --euid root --full ".*openvpn.*${ovpn_file##*/}.*")

if [[ "$1" == "--disconnect" ]]; then
  echo "Stopping any existing VPN connections"
  if [[ "${#ovpn_pid[@]}" -ne 0 ]]; then
    timeout 5 kill "${ovpn_pid[@]}" || kill -9 "${ovpn_pid[@]}" \
      && echo "Stopped ${#ovpn_pid[@]} connection(s)"
  else
    echo "No active connections"
  fi
  exit
elif [[ "${#ovpn_pid[@]}" -ne 0 ]]; then
  echo "OpenVPN is already running with your configuration file."
  echo "Stop it first with sudo $0 --disconnect"
  exit 1
fi

# check for Internet using Google and ISC
public_addrs=("8.8.8.8" "192.5.5.241")
until ping -c2 -i.2 -W1 "${public_addrs[0]}" &>/dev/null; do
  public_addrs=("${public_addrs[@]:1}")
  if [[ "${#public_addrs[@]}" -eq 0 ]]; then
    echo "Unable to connect to the Internet."
    exit 1
  fi
done

echo "Starting VPN connection"
openvpn --config "$ovpn_file" --log .openvpn.log --daemon

check_connected_command="while ! grep 'Initialization Sequence Completed' .openvpn.log; do sleep 1; done"
check_connection_command="while ! ping -c 1 -W1 10.0.0.2 &>/dev/null; do sleep 1; done"

if timeout 10 bash -c "$check_connected_command" &>/dev/null \
  && timeout 10 bash -c "$check_connection_command" &>/dev/null; then
  declare -a overlapping_rules
  for i in {0..7}; do
    rule="$(ip route get fibmatch "10.0.${i}.5")"
    if [[ ! "$rule" =~ \ dev\ tun_ethhak\ *$ ]]; then
      overlapping_rules+=("$rule")
    fi
  done
  if [[ "${#overlapping_rules[@]}" -ne 0 ]]; then
    echo "Warning: your routing table contains overlapping rules:"
    printf "\t%s\n" "${overlapping_rules[@]}" | sort -u
    echo "This means that you won't be able to reach those parts of the cyber range."
    if sudo dmesg | grep -q "Hypervisor detected: "; then
      echo "Please change the network of your virtual interface to be outside of 10.0.0.0/20."
      echo "Refer to the \"VPN installation\" page on Canvas for how to resolve the conflict."
    else
      echo "It seems that you are not using a virtual machine."
      echo "Please contact the course support team."
    fi
  fi
  echo 'VPN connection successful.'
else
  echo 'VPN connection was unsuccessful for some reason.'
  echo 'Make sure that you are not connected from another machine.'
  echo 'If the issue persists, please contact the course support team '
  echo "and attach your ${0%/*}/.openvpn.log."
  exit 1
fi
