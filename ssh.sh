#!/usr/bin/expect -f
set timeout 200
spawn ssh-keygen -R {[localhost]:2222}
expect eof
spawn ssh -p 2222 root@localhost
expect {
  -re "Are you sure you want to continue connecting" { send "yes\r"; exp_continue }
  -re "(?i)password:" { send "root\r" }
}
interact
