# 阿里云 → 火山引擎 服务器迁移专项清单

适用：阿里云 ECS 单机迁移到火山引擎 ECS。本技能矩阵验证**软件层**（包/配置/用户/cron）；
云资源层（VPC/EIP/安全组/镜像）按本清单在控制台处理。

## 0. 总体策略

只搬软件与数据，不换架构。顺序：**先在火山备好空机 → 矩阵验证软件栈 → 同步数据 → 切流 → 观察期 → 释放旧机**。
旧机全程保留，切流后观察 7–15 天再释放。

## 1. 目标机 OS 选择

| 选项 | 说明 |
| --- | --- |
| Ubuntu 22.04 / 24.04 LTS | 推荐，软件栈最通用；矩阵已覆盖 noble，可加 jammy |
| Debian 12 | 矩阵已覆盖 bookworm |
| CentOS Stream 9 | RHEL 兼容；矩阵已覆盖 |
| veLinux（火山自研） | RHEL 兼容系，用 rocky/stream 的 dnf 结论类推；Docker Hub 无镜像，矩阵无法直连模拟 |

原则：目标 OS 尽量与源机同大版本；源机若是 Alibaba Cloud Linux（CentOS 兼容），目标选 Stream 9 / Rocky 9 类 dnf 系。

## 2. 软件层（用本技能矩阵验证）

1. 源机跑 `scripts/snapshot.sh`，`plan_from_snapshot.py` 生成计划。
2. 重点核对：
   - 包清单：阿里云源机可能装了 `aliyun-service`、云监控 agent，火山无对应，**不要迁移**，在计划里剔除。
   - nginx/Apache 配置目录差异（见 `distro-matrix.md`）。
   - cron 任务全部迁入 `/etc/cron.d`。
   - 业务用户/组重建，UID 不必一致。
   - **业务二进制**：`/server` 下的产物要核对 glibc 下限（`ldd` + `strings | grep GLIBC_`）。
     实测 proxysss v1.3.9（Ubuntu 24.04 编译，要求 GLIBC_2.38/2.39）在 Debian 12 / Ubuntu 22.04 / Alma/Rocky 9 上
     全部起不来，Alpine(musl) 直接 not found。目标 OS 必须与构建环境 glibc 对齐，或改 musl 静态产物，详见 `business-stack.md`。
3. `python scripts/matrix.py all` 出报告，FAIL 项按报告修计划。
   业务栈计划要带 `dirs`（`/server`）、`units`、`services`（起进程 + 端口归属校验），只验包和文件会漏掉「起不来」。

## 3. 数据迁移（文件级，跨云不做整盘搬运）

| 数据类型 | 方式 |
| --- | --- |
| 静态文件/站点 | `rsync -avz --delete` 多次同步，最后一次停业务增量收尾 |
| MySQL/MariaDB | `mysqldump` 逻辑导出 → 目标机导入；避免直接拷数据文件 |
| Redis | 导 RDB/AOF 或 `redis-cli --rdb`；清空后恢复，注意持久化配置 |
| 大文件/对象 | 阿里云 OSS → 火山 TOS（oss2 / tosutil 或迁移工具），不要走服务器中转 |
| 数据库实例（RDS/PolarDB） | 跨云不迁移实例，导出后自建或选火山托管 |

> 跨云没有"整盘快照直接导入"：阿里云镜像不能直接转火山盘，一律文件/逻辑级迁移。

## 4. 网络与云资源清单

- [ ] 火山侧新建 VPC / 子网 / 交换机（与阿里云内网不通，不能沿用）。
- [ ] 安全组重配：放行 22（限办公 IP）、80、443；阿里云旧安全组规则不带过来。
- [ ] 弹性公网 IP（EIP）：目标机新建并绑定；不保留旧公网 IP。
- [ ] 域名 DNS：切流前把解析 TTL 降到 60s；切流时 A 记录改到火山 EIP。
- [ ] 如旧机绑了 SLB/CDN/WAF，火山侧对应重建（CLB/CDN）。

## 5. 服务与端口核对

- 矩阵已验证业务进程真能起、端口归属正确（`svc:` 检查）；目标机经 `prod_deploy` 部署后由 systemd 托管并原地复验。
- 业务网关用 proxysss（替代 nginx）：`fetch_proxysss.py` 拉 v1.3.15+ 静态产物，7 发行版通用；80/443 + UDP 443（H3）+ admin 127.0.0.1:7777 按 `business-stack.md` 清单核对。
- 本地防火墙：旧机 ufw/iptables 规则**不照搬**，按目标安全组策略重写。
- 外部回调/白名单：支付、短信、OAuth 回调里写死的旧 IP 要改成新 EIP。

## 6. 切流与回滚

1. 目标机部署：`python scripts/prod_deploy.py --plan <plan> --transport ssh --target root@<火山EIP>`（自动备份 + 原地校验）；失败 `--rollback` 恢复。
2. 观察期前：旧机只读、新机备用，rsync 做最后增量。
3. 切流：DNS 切到新 EIP；保留旧机运行。
4. 观察 7–15 天：看日志、错误率、业务上报；异常则 DNS 切回（TTL 已调低，生效快），目标机必要时 `--rollback`。
5. 确认稳定后释放旧 EIP 与旧机，销毁阿里云实例。

## 7. 切前检查清单（逐项打勾）

- [ ] 软件栈矩阵报告全 PASS
- [ ] `prod_deploy` 目标机报告全 PASS（report/target-report.md）
- [ ] 站点/应用文件 rsync 完成并校验（`rsync -avn` 干跑比对）
- [ ] 数据库导出/导入完成，行数抽样核对
- [ ] cron 任务全部在 `/etc/cron.d`（Alpine 为 /etc/crontabs/root 标记块）
- [ ] 业务用户/组已建
- [ ] 安全组、EIP、VPC 就绪
- [ ] DNS TTL 已调低
- [ ] 回滚方案：旧机保留、DNS 切回路径明确、目标机 `--rollback` 已预演
