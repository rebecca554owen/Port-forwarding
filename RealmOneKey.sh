#!/bin/bash

# 检查realm是否已安装及服务状态
check_realm_status() {
    if [ -f "/opt/realm/realm" ]; then
        echo "检测到realm已安装。"
        realm_status="已安装"
        realm_status_color="\033[0;32m" # 绿色

        if systemctl is-active --quiet realm; then
            realm_service_status="启用"
            realm_service_color="\033[0;32m" # 绿色
        else
            realm_service_status="未启用"
            realm_service_color="\033[0;31m" # 红色
        fi
    else
        echo "realm未安装。"
        realm_status="未安装"
        realm_status_color="\033[0;31m" # 红色
        realm_service_status="未启用"
        realm_service_color="\033[0;31m" # 红色
    fi
}

# 下载并安装realm的函数
deploy_realm() {
    mkdir -p /opt/realm
    wget -O /opt/realm/realm.tar.gz https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf /opt/realm/realm.tar.gz -C /opt/realm
    chmod +x /opt/realm/realm

    # 创建配置文件
    cat <<EOF > /opt/realm/config.toml
[log]
level = "warn"
output = "/var/log/realm.log"

[[endpoints]]
listen = "0.0.0.0:10000"
remote = "www.google.com:443"
EOF

    # 创建服务文件
    cat <<EOF > /etc/systemd/system/realm.service
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/opt/realm
ExecStart=/opt/realm/realm -c /opt/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now realm

    # 更新realm状态变量
    realm_status="已安装"
    realm_status_color="\033[0;32m" # 绿色

    # 检查服务是否启动成功
    if systemctl is-active --quiet realm; then
        echo "下载并安装成功。"
    else
        echo "下载并安装成功，但启动失败。请检查配置。"
    fi
}

# 卸载realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /opt/realm
    echo "realm已被卸载。"
    # 更新realm状态变量
    realm_status="未安装"
    realm_status_color="\033[0;31m" # 红色
    realm_service_status="未启用"
    realm_service_color="\033[0;31m" # 红色
}

# 删除转发规则的函数
delete_forward() {
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n '^\[\[endpoints\]\]' /opt/realm/config.toml))

    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    local blocks=()
    for ((i = 0; i < ${#lines[@]}; i++)); do
        local start_line=$(echo ${lines[$i]} | cut -d ':' -f 1)
        local end_line=$((${lines[$i + 1]:-$(wc -l < /opt/realm/config.toml)} - 1))
        blocks+=("$start_line:$end_line")
        echo "${index}. $(sed -n "${start_line},${end_line}p" /opt/realm/config.toml | grep 'listen\|remote')"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#blocks[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_block=${blocks[$((choice - 1))]}
    local start_line=$(echo $chosen_block | cut -d ':' -f 1)
    local end_line=$(echo $chosen_block | cut -d ':' -f 2)

    sed -i "${start_line},${end_line}d" /opt/realm/config.toml

    echo "转发规则已删除。"
    start_service
}

# 添加转发规则
add_forward() {
    while true; do
        read -p "请输入本机监听端口: " listen_port
        read -p "请输入目标IP或域名: " target_ip
        read -p "请输入目标端口: " target_port
        # 追加到config.toml文件
        cat <<EOF >> /opt/realm/config.toml
[[endpoints]]
listen = "0.0.0.0:$listen_port"
remote = "$target_ip:$target_port"
EOF
        
        read -p "是否继续添加(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            break
        fi
    done
    start_service
}

# 启动服务
start_service() {
    systemctl daemon-reload
    systemctl restart realm.service
    systemctl enable realm.service
    if systemctl is-active --quiet realm; then
        echo "realm服务已启动并设置为开机自启。"
    else
        echo "启动realm服务失败。"
    fi
}

# 停止服务
stop_service() {
    systemctl stop realm
    echo "realm服务已停止。"
}

# 显示菜单的函数
show_menu() {
    clear
    check_realm_status
    echo "欢迎使用realm一键转发脚本"
    echo "================="
    echo "1. 下载并安装realm"
    echo "2. 添加转发"
    echo "3. 删除转发"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 一键卸载"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -e "realm 服务状态：${realm_service_color}${realm_service_status}\033[0m"
}

# 主循环
while true; do
    show_menu
    read -p "请选择一个选项: " choice
    case $choice in
        1)
            deploy_realm
            ;;
        2)
            add_forward
            ;;
        3)
            delete_forward
            ;;
        4)
            start_service
            ;;
        5)
            stop_service
            ;;
        6)
            uninstall_realm
            ;;
        *)
            echo "无效选项: $choice"
            ;;
    esac
    read -p "按任意键继续..." key
done
