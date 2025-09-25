#!/bin/sh


PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Cài đặt 3proxy
install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://sharettt.com/multimedia/3proxy-3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

# Tạo file cấu hình 3proxy
gen_3proxy() {
    cat <<EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Tạo file proxy cho người dùng
gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

# Tạo dữ liệu người dùng proxy
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Tạo các iptables
gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

# Tạo cấu hình cho ifconfig
gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

# Tạo script khởi động tổng hợp
create_startup_script() {
    cat <<'EOF' > /usr/local/bin/start_3proxy_system
#!/bin/bash

# Đợi kết nối mạng hoạt động
while ! ping -c 1 -W 1 google.com &> /dev/null; do
    sleep 1
done

# Đợi thêm 5 giây để đảm bảo
sleep 5

# Áp dụng cấu hình IPv6
/bin/bash /home/vpsttt/boot_ifconfig.sh

# Áp dụng iptables rules
/bin/bash /home/vpsttt/boot_iptables.sh

# Đặt giới hạn file descriptor
ulimit -n 65535

# Khởi động 3proxy
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF

    chmod +x /usr/local/bin/start_3proxy_system
}

# Cài đặt các gói cần thiết
echo "Installing apps..."
yum -y install gcc net-tools bsdtar zip >/dev/null

# Cài đặt 3proxy
install_3proxy

# Xác định thư mục làm việc
echo "Working folder = /home/vpsttt"
WORKDIR="/home/vpsttt"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $_

# Lấy địa chỉ IP v4 và v6 của VPS
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP = ${IP4}. External sub for IP6 = ${IP6}"

FIRST_PORT=10000
LAST_PORT=11300

# Tạo dữ liệu proxy và các script cấu hình
gen_data >$WORKDIR/data.txt
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh

# Cấp quyền thực thi cho các script
chmod +x $WORKDIR/boot_iptables.sh
chmod +x $WORKDIR/boot_ifconfig.sh

# Tạo cấu hình 3proxy
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

# Tạo script khởi động tổng hợp
create_startup_script

# Tạo systemd service cho 3proxy
cat <<EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/start_3proxy_system
Restart=always
RestartSec=10
User=root
LimitNOFILE=65535
KillMode=process

# Đảm bảo clean shutdown
ExecStop=/bin/kill -TERM \$MAINPID
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

# Kích hoạt network-wait-online
systemctl enable systemd-networkd-wait-online.service

# Kích hoạt và khởi động dịch vụ 3proxy
systemctl daemon-reload
systemctl enable 3proxy.service
systemctl start 3proxy.service

# Tạo file proxy cho người dùng
gen_proxy_file_for_user

# Xóa các file không cần thiết
rm -rf /root/3proxy-3proxy-0.8.6

# Kiểm tra trạng thái dịch vụ
echo "Kiểm tra trạng thái 3proxy..."
systemctl status 3proxy.service --no-pager -l

echo "Cấu hình hoàn tất. 3proxy sẽ tự động khởi động sau mỗi lần reboot."
