#!/bin/bash
# gitlab_migration.sh - GitLab EE 完整迁移备份脚本
# 适用于绑定挂载方式，数据目录：/data/gitlab/
# 作者：根据您的需求定制
# 日期：$(date +%Y-%m-%d)

set -e  # 遇到错误立即退出

# ==================== 配置区域 ====================
CONTAINER_NAME="gitlab"                  # 容器名称
GITLAB_DATA_DIR="/data/gitlab"           # 数据目录
BACKUP_BASE_DIR="/backup/gitlab-migration"  # 备份基目录
MIGRATION_DATE=$(date +%Y%m%d_%H%M%S)   # 时间戳
BACKUP_DIR="${BACKUP_BASE_DIR}/${MIGRATION_DATE}"  # 备份目录
LOG_FILE="${BACKUP_DIR}/backup.log"     # 日志文件
RSYNC_EXCLUDE="*.tmp,*.log,*.lock"      # 排除的文件类型

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==================== 函数定义 ====================

# 打印带颜色的消息
print_msg() {
    echo -e "${2}${1}${NC}"
}

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        print_msg "错误: $1 命令未找到，请先安装" $RED
        exit 1
    fi
}

# 检查磁盘空间
check_disk_space() {
    local data_size=$(sudo du -s ${GITLAB_DATA_DIR} | awk '{print $1}')
    local available_space=$(df ${BACKUP_BASE_DIR} | awk 'NR==2 {print $4}')
    local required_space=$((data_size * 120 / 100))  # 需要额外20%空间
    
    if [ $available_space -lt $required_space ]; then
        print_msg "错误: 磁盘空间不足！" $RED
        print_msg "数据大小: $(echo "scale=2; $data_size/1024/1024" | bc)GB" $YELLOW
        print_msg "可用空间: $(echo "scale=2; $available_space/1024/1024" | bc)GB" $YELLOW
        print_msg "需要空间: $(echo "scale=2; $required_space/1024/1024" | bc)GB" $YELLOW
        exit 1
    fi
    print_msg "✓ 磁盘空间检查通过" $GREEN
}

# 备份前检查
pre_backup_check() {
    print_msg "=== 开始预检检查 ===" $YELLOW
    
    # 检查必要命令
    check_command docker
    check_command rsync
    check_command tar
    check_command du
    
    # 检查容器状态
    if ! sudo docker ps --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        print_msg "错误: 容器 '${CONTAINER_NAME}' 未运行" $RED
        exit 1
    fi
    
    # 检查数据目录
    if [ ! -d "${GITLAB_DATA_DIR}" ]; then
        print_msg "错误: 数据目录 ${GITLAB_DATA_DIR} 不存在" $RED
        exit 1
    fi
    
    # 检查磁盘空间
    check_disk_space
    
    print_msg "✓ 所有预检检查通过" $GREEN
}

# 创建备份目录
create_backup_dir() {
    print_msg "创建备份目录: ${BACKUP_DIR}" $YELLOW
    sudo mkdir -p "${BACKUP_DIR}"
    sudo chmod 755 "${BACKUP_DIR}"
    print_msg "✓ 备份目录创建完成" $GREEN
}

# 备份关键元数据
backup_metadata() {
    print_msg "=== 备份元数据 ===" $YELLOW
    
    # 备份容器配置
    print_msg "备份容器配置信息..." $YELLOW
    sudo docker inspect ${CONTAINER_NAME} > "${BACKUP_DIR}/container-inspect.json"
    sudo docker logs --tail 500 ${CONTAINER_NAME} 2>&1 > "${BACKUP_DIR}/container-logs.log"
    
    # 备份 GitLab 密钥（至关重要！）
    print_msg "备份 GitLab 密钥..." $YELLOW
    if sudo docker exec ${CONTAINER_NAME} test -f /etc/gitlab/gitlab-secrets.json; then
        sudo docker exec ${CONTAINER_NAME} cat /etc/gitlab/gitlab-secrets.json > "${BACKUP_DIR}/gitlab-secrets.json"
        print_msg "✓ GitLab 密钥备份完成" $GREEN
    else
        print_msg "警告: 未找到 gitlab-secrets.json" $YELLOW
    fi
    
    # 备份配置文件
    print_msg "备份配置文件..." $YELLOW
    if [ -f "${GITLAB_DATA_DIR}/etc/gitlab.rb" ]; then
        sudo cp "${GITLAB_DATA_DIR}/etc/gitlab.rb" "${BACKUP_DIR}/gitlab.rb.bak"
        print_msg "✓ 配置文件备份完成" $GREEN
    fi
    
    # 记录版本信息
    sudo docker exec ${CONTAINER_NAME} cat /opt/gitlab/version-manifest.txt 2>/dev/null > "${BACKUP_DIR}/version-manifest.txt" || true
    sudo docker images --digests | grep gitlab-ee > "${BACKUP_DIR}/docker-images.txt"
}

# 创建 GitLab 应用备份
create_gitlab_backup() {
    print_msg "=== 创建 GitLab 应用备份 ===" $YELLOW
    
    # 设置维护模式
    print_msg "启用 GitLab 维护模式..." $YELLOW
    sudo docker exec ${CONTAINER_NAME} gitlab-ctl deploy-page up
    
    # 创建备份（使用 copy 策略减少锁定时间）
    print_msg "开始创建 GitLab 应用备份（这可能需要一些时间）..." $YELLOW
    sudo docker exec ${CONTAINER_NAME} gitlab-backup create \
        STRATEGY=copy \
        SKIP=tar \
        CRON=1 \
        2>&1 | tee -a "${LOG_FILE}"
    
    # 查找备份文件
    local backup_file=$(sudo docker exec ${CONTAINER_NAME} \
        bash -c 'ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1')
    
    if [ -n "$backup_file" ]; then
        local backup_name=$(basename "$backup_file")
        print_msg "✓ GitLab 应用备份创建完成: ${backup_name}" $GREEN
        
        # 复制备份文件到备份目录
        sudo cp "${GITLAB_DATA_DIR}/opt/backups/${backup_name}" "${BACKUP_DIR}/"
        
        # 验证备份文件
        local backup_size=$(sudo ls -lh "${BACKUP_DIR}/${backup_name}" | awk '{print $5}')
        print_msg "备份文件大小: ${backup_size}" $GREEN
    else
        print_msg "警告: 未找到 GitLab 备份文件" $YELLOW
    fi
    
    # 关闭维护模式
    sudo docker exec ${CONTAINER_NAME} gitlab-ctl deploy-page down
}

# 备份数据目录
backup_data_directories() {
    print_msg "=== 备份数据目录 ===" $YELLOW
    
    # 停止 GitLab 容器以确保数据一致性
    print_msg "停止 GitLab 容器..." $YELLOW
    sudo docker stop ${CONTAINER_NAME}
    
    # 等待服务完全停止
    sleep 30
    
    # 使用 rsync 备份数据目录（保持所有权限和属性）
    print_msg "备份 /data/gitlab 目录（96GB，这需要较长时间）..." $YELLOW
    print_msg "开始时间: $(date)" $YELLOW
    
    sudo rsync -aAXv \
        --progress \
        --exclude='*.tmp' \
        --exclude='*.log' \
        --exclude='cache/*' \
        --exclude='tmp/*' \
        "${GITLAB_DATA_DIR}/" \
        "${BACKUP_DIR}/data-snapshot/" \
        2>&1 | tee -a "${LOG_FILE}"
    
    print_msg "结束时间: $(date)" $YELLOW
    print_msg "✓ 数据目录备份完成" $GREEN
    
    # 启动 GitLab 容器
    print_msg "启动 GitLab 容器..." $YELLOW
    sudo docker start ${CONTAINER_NAME}
    
    # 等待容器启动
    sleep 10
    
    # 检查容器状态
    if sudo docker ps | grep -q ${CONTAINER_NAME}; then
        print_msg "✓ GitLab 容器已成功启动" $GREEN
    else
        print_msg "警告: GitLab 容器启动可能有问题" $YELLOW
        sudo docker logs ${CONTAINER_NAME} --tail 20
    fi
}

# 创建压缩包（可选）
create_archive() {
    print_msg "=== 创建压缩归档 ===" $YELLOW
    
    local archive_name="gitlab-backup-${MIGRATION_DATE}.tar.gz"
    
    print_msg "创建压缩包: ${archive_name} ..." $YELLOW
    print_msg "这可能需要很长时间，请耐心等待..." $YELLOW
    
    # 切换到备份目录的父目录
    cd "${BACKUP_BASE_DIR}"
    
    # 创建压缩包，排除日志文件以节省空间
    sudo tar -czf "${archive_name}" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        "${MIGRATION_DATE}/"
    
    local archive_size=$(sudo ls -lh "${archive_name}" | awk '{print $5}')
    print_msg "✓ 压缩包创建完成: ${archive_size}" $GREEN
    
    # 计算 MD5 校验和
    sudo md5sum "${archive_name}" > "${archive_name}.md5"
    print_msg "MD5 校验和: $(cat ${archive_name}.md5)" $GREEN
    
    echo "${BACKUP_BASE_DIR}/${archive_name}"
}

# 生成恢复指南
generate_recovery_guide() {
    print_msg "=== 生成恢复指南 ===" $YELLOW
    
    cat > "${BACKUP_DIR}/恢复指南.md" << EOF
# GitLab EE 迁移恢复指南

## 备份信息
- 备份时间: ${MIGRATION_DATE}
- 容器名称: ${CONTAINER_NAME}
- 数据目录: ${GITLAB_DATA_DIR}
- 总数据量: 96GB
- 备份位置: ${BACKUP_DIR}

## 包含的备份内容
1. GitLab 应用备份: \`*_gitlab_backup.tar\`
2. 数据目录快照: \`data-snapshot/\`
3. 容器配置: \`container-inspect.json\`
4. GitLab 密钥: \`gitlab-secrets.json\`
5. 配置文件: \`gitlab.rb.bak\`
6. 版本信息: \`version-manifest.txt\`

## 恢复步骤

### 1. 准备新服务器
\`\`\`bash
# 安装 Docker
sudo apt-get update
sudo apt-get install docker.io docker-compose

# 创建数据目录
sudo mkdir -p /data/gitlab/{opt,etc,log}
sudo chmod -R 755 /data/gitlab
\`\`\`

### 2. 传输备份文件
\`\`\`bash
# 从源服务器复制（在新服务器执行）
rsync -avP tadeic@源服务器IP:${BACKUP_DIR}/ /备份目标路径/

# 或者复制压缩包
scp tadeic@源服务器IP:${BACKUP_BASE_DIR}/gitlab-backup-${MIGRATION_DATE}.tar.gz .
tar -xzf gitlab-backup-${MIGRATION_DATE}.tar.gz
\`\`\`

### 3. 恢复数据
\`\`\`bash
# 恢复数据目录
sudo rsync -aAX ${BACKUP_DIR}/data-snapshot/ /data/gitlab/

# 恢复密钥文件
sudo cp ${BACKUP_DIR}/gitlab-secrets.json /data/gitlab/etc/

# 恢复配置文件
sudo cp ${BACKUP_DIR}/gitlab.rb.bak /data/gitlab/etc/gitlab.rb
\`\`\`

### 4. 启动 GitLab 容器
\`\`\`bash
# 使用相同版本的镜像
docker run -d \\
  --hostname gitlab.example.com \\
  --name gitlab \\
  --restart always \\
  -v /data/gitlab/etc:/etc/gitlab \\
  -v /data/gitlab/opt:/var/opt/gitlab \\
  -v /data/gitlab/log:/var/log/gitlab \\
  -p 80:80 -p 443:443 -p 22:22 \\
  gitlab/gitlab-ee:相同版本号
\`\`\`

### 5. 执行应用恢复
\`\`\`bash
# 进入容器
docker exec -it gitlab bash

# 停止相关服务
gitlab-ctl stop puma
gitlab-ctl stop sidekiq

# 执行恢复（替换 BACKUP_ID）
gitlab-backup restore BACKUP=BACKUP_ID

# 重新配置并重启
gitlab-ctl reconfigure
gitlab-ctl restart
\`\`\`

### 6. 验证恢复
\`\`\`bash
# 运行健康检查
gitlab-rake gitlab:check SANITIZE=true

# 检查服务状态
gitlab-ctl status
\`\`\`

## 注意事项
1. 确保新服务器有足够磁盘空间（至少 200GB）
2. 使用与源服务器相同版本的 GitLab EE 镜像
3. 恢复前备份新服务器的任何现有数据
4. 恢复过程中不要中断电源或网络
5. 恢复后立即测试所有主要功能

## 故障排除
- 如果恢复失败，检查 \`/var/log/gitlab/\` 目录下的日志
- 确保 \`gitlab-secrets.json\` 文件权限正确（600）
- 如果端口冲突，修改 docker run 命令中的端口映射

## 联系信息
如有问题，请联系系统管理员。

---
*备份完成时间: $(date)*
EOF

    print_msg "✓ 恢复指南生成完成" $GREEN
}

# 清理旧备份
cleanup_old_backups() {
    print_msg "=== 清理旧备份 ===" $YELLOW
    
    # 保留最近7天的备份
    local keep_days=7
    print_msg "清理 ${keep_days} 天前的备份..." $YELLOW
    
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "2*" -mtime +${keep_days} | while read dir; do
        print_msg "删除旧备份: ${dir}" $YELLOW
        sudo rm -rf "${dir}"
    done
    
    # 清理旧的压缩包
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type f -name "gitlab-backup-*.tar.gz" -mtime +${keep_days} | while read file; do
        print_msg "删除旧压缩包: ${file}" $YELLOW
        sudo rm -f "${file}"
    done
    
    print_msg "✓ 备份清理完成" $GREEN
}

# 生成摘要报告
generate_summary() {
    print_msg "=== 备份摘要 ===" $GREEN
    
    local data_size=$(sudo du -sh ${GITLAB_DATA_DIR} | awk '{print $1}')
    local backup_size=$(sudo du -sh ${BACKUP_DIR} | awk '{print $1}')
    
    cat > "${BACKUP_DIR}/备份摘要.txt" << EOF
GitLab EE 迁移备份摘要
=======================

备份时间:     ${MIGRATION_DATE}
容器名称:     ${CONTAINER_NAME}
源数据大小:   ${data_size}
备份大小:     ${backup_size}
备份位置:     ${BACKUP_DIR}

包含内容:
1. GitLab 应用备份
2. 完整数据目录快照
3. 容器配置和元数据
4. GitLab 密钥文件
5. 配置文件备份
6. 版本信息
7. 恢复指南

状态: 备份成功

磁盘使用情况:
$(df -h ${BACKUP_BASE_DIR})

重要提醒:
1. 验证备份文件的完整性
2. 安全存储 gitlab-secrets.json
3. 恢复时使用相同版本镜像
4. 测试恢复后的系统功能

备份完成时间: $(date)
EOF
    
    # 显示摘要
    cat "${BACKUP_DIR}/备份摘要.txt"
}

# 主函数
main() {
    print_msg "==========================================" $GREEN
    print_msg "GitLab EE 完整迁移备份脚本" $GREEN
    print_msg "开始时间: $(date)" $GREEN
    print_msg "==========================================" $GREEN
    
    # 执行备份流程
    pre_backup_check
    create_backup_dir
    exec > >(tee -a "${LOG_FILE}") 2>&1  # 记录所有输出到日志
    
    backup_metadata
    create_gitlab_backup
    backup_data_directories
    generate_recovery_guide
    
    # 可选：创建压缩包（96GB数据压缩会很慢）
    print_msg "是否创建压缩包？(y/n)" $YELLOW
    read -t 30 -p "等待30秒，默认不压缩 [n]: " compress_choice
    compress_choice=${compress_choice:-n}
    
    if [[ $compress_choice =~ ^[Yy]$ ]]; then
        archive_path=$(create_archive)
        print_msg "压缩包位置: ${archive_path}" $GREEN
    fi
    
    # 清理和总结
    cleanup_old_backups
    generate_summary
    
    print_msg "==========================================" $GREEN
    print_msg "备份完成！" $GREEN
    print_msg "总耗时: $SECONDS 秒" $GREEN
    print_msg "备份目录: ${BACKUP_DIR}" $GREEN
    print_msg "日志文件: ${LOG_FILE}" $GREEN
    print_msg "==========================================" $GREEN
    
    # 显示最终磁盘使用情况
    print_msg "最终磁盘使用情况:" $YELLOW
    df -h ${BACKUP_BASE_DIR}
}

# ==================== 脚本入口 ====================
if [[ $EUID -ne 0 ]]; then
    print_msg "请使用 sudo 运行此脚本: sudo $0" $RED
    exit 1
fi

# 启动主函数
main "$@"