#!/bin/bash

# 检查realm是否已安装及服务状态
check_realm_status() {
    if [ -f "/opt/realm/realm" ]; then
        echo "检测到realm已安装。"
        realm_status="已安装"
        if systemctl is-active --quiet realm; then
            realm_service_status="启用"
        else
            realm_service_status="未启用"
        fi
    else
        echo "realm未安装。"
        realm_status="未安装"
        realm_service_status="未启用"
    fi
}

# 启动服务
start_service() {
    if ! grep -q '^\[\[endpoints\]\]' /opt/realm/config.toml; then
        echo "配置文件中没有规则块，无法启动服务。"
        return
    fi

    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm

    if systemctl is-active --quiet realm; then
        echo "realm服务已启动并设置为开机自启。"
    else
        echo "启动realm服务失败。请查看日志获取更多信息。"
        systemctl status realm
        journalctl -u realm.service -e
    fi
}

# 下载并安装realm
deploy_realm() {
    mkdir -p /opt/realm
    wget -O /opt/realm/realm.tar.gz https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf /opt/realm/realm.tar.gz -C /opt/realm
    chmod +x /opt/realm/realm

    # 创建日志文件并设置权限
    touch /opt/realm/realm.log
    chmod 777 /opt/realm/realm.log

    # 创建配置文件
    cat <<EOF > /opt/realm/config.toml
[log]
level = "warn"
output = "/opt/realm/realm.log"

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
WorkingDirectory=/opt/realm
ExecStart=/opt/realm/realm -c /opt/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF

    # 更新realm状态变量
    realm_status="已安装"

    # 启动服务
    start_service
}

# 停止服务
stop_service() {
    systemctl stop realm
    if systemctl is-active --quiet realm; then
        echo "停止realm服务失败。"
    else
        echo "realm服务已停止。"
    fi
}

# 卸载realm
uninstall_realm() {
    stop_service
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /opt/realm
    echo "realm已被卸载。"
}

# 列出转发规则
list_forwards() {
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n '^\[\[endpoints\]\]' /opt/realm/config.toml))

    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    local index=1
    local total_lines=$(wc -l < /opt/realm/config.toml)
    for ((i = 0; i < ${#lines[@]}; i++)); do
        local start_line=$(echo ${lines[$i]} | cut -d ':' -f 1)
        local end_line=$(($total_lines))
        if [ $i -lt $((${#lines[@]} - 1)) ]; then
            end_line=$(echo ${lines[$((i + 1))]} | cut -d ':' -f 1)
            end_line=$((end_line - 1))
        fi

        local listen=$(sed -n "${start_line},${end_line}p" /opt/realm/config.toml | grep 'listen' | cut -d '=' -f 2 | tr -d ' "')
        local remote=$(sed -n "${start_line},${end_line}p" /opt/realm/config.toml | grep 'remote' | cut -d '=' -f 2 | tr -d ' "')
        
        echo -e "${index}. listen = ${listen}, remote = ${remote}"
        let index+=1
    done
}

# 添加或修改转发规则
configure_forward() {
    local action=$1
    local start_line=$2
    local end_line=$3

    read -p "请输入本机监听端口: " listen_port
    read -p "请输入目标IP或域名: " target_ip
    read -p "请输入目标端口: " target_port
    read -p "是否使用WebSocket隧道 (yes/no): " use_ws

    if [[ "$use_ws" == "yes" ]]; then
        read -p "请输入WebSocket的host: " ws_host
        read -p "请输入WebSocket的path: " ws_path
        local forward_config="[[endpoints]]
listen = \"0.0.0.0:$listen_port\"
remote = \"$target_ip:$target_port\"
remote_transport = \"ws;host=$ws_host;path=$ws_path\""
    else
        local forward_config="[[endpoints]]
listen = \"0.0.0.0:$listen_port\"
remote = \"$target_ip:$target_port\""
    fi

    if [[ "$action" == "add" ]]; then
        echo -e "$forward_config" >> /opt/realm/config.toml
    elif [[ "$action" == "modify" ]]; then
        sed -i "${start_line},${end_line}d" /opt/realm/config.toml
        echo -e "$forward_config" >> /opt/realm/config.toml
    fi

    start_service
}

# 删除转发规则
delete_forward() {
    list_forwards

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

    local lines=($(grep -n '^\[\[endpoints\]\]' /opt/realm/config.toml))
    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local start_line=$(echo ${lines[$((choice - 1))]} | cut -d ':' -f 1)
    local end_line=$(wc -l < /opt/realm/config.toml)
    if [ $choice -lt ${#lines[@]} ]; then
        end_line=$(echo ${lines[$choice]} | cut -d ':' -f 1)
        end_line=$((end_line - 1))
    fi

    sed -i "${start_line},${end_line}d" /opt/realm/config.toml

    echo "转发规则已删除。"
    start_service
}

# 修改转发规则
modify_forward() {
    list_forwards

    echo "请输入要修改的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    local lines=($(grep -n '^\[\[endpoints\]\]' /opt/realm/config.toml))
    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local start_line=$(echo ${lines[$((choice - 1))]} | cut -d ':' -f 1)
    local end_line=$(wc -l < /opt/realm/config.toml)
    if [ $choice -lt ${#lines[@]} ]; then
        end_line=$(echo ${lines[$choice]} | cut -d ':' -f 1)
        end_line=$((end_line - 1))
    fi

    configure_forward "modify" "$start_line" "$end_line"
}

# 添加转发规则
add_forward() {
    configure_forward "add"
}

# 显示菜单的函数
show_menu() {
    clear
    check_realm_status
    echo "欢迎使用realm一键转发脚本"
    echo "realm 状态：${realm_status}"
    echo "realm 服务状态：${realm_service_status}"
    echo "================="
    echo "1. 安装realm"
    echo "2. 添加转发"
    echo "3. 删除转发"
    echo "4. 修改转发"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 查看规则"
    echo "8. 一键卸载"
    echo "================="
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
            modify_forward
            ;;
        5)
            start_service
            ;;
        6)
            stop_service
            ;;
        7)
            list_forwards
            ;;
        8)
            uninstall_realm
            break
            ;;
        *)
            echo "无效选项: $choice"
            ;;
    esac
    read -p "按任意键继续..." key
done
