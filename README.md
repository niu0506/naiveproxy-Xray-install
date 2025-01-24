# 一键安装 NaiveProxy + Xray

这个项目提供了一个一键安装脚本，用于快速部署 NaiveProxy 和 Xray 的联合使用。通过这个脚本，你可以轻松地搭建一个高性能的代理服务。

## 优化Linux

运行以下命令来优化Linux：
1.保存为文件并授权

```
curl -fsSL https://raw.githubusercontent.com/niu0506/naiveproxy-Xray-install/refs/heads/main/bbr.sh -o tune_bbr.sh
chmod +x tune_bbr.sh
bash tune_bbr.sh
```
2.日志记录（推荐）
```
sudo ./tune_bbr.sh 2>&1 | tee /var/log/bbr_tuning.log
```
3.卸载还原
```
sudo rm -f /etc/sysctl.d/99-bbr.conf
sudo sysctl --system
```

## 安装

运行以下命令来安装 NaiveProxy 和 Xray：

```
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/niu0506/naiveproxy-hysteria-Xray-install/main/install.sh" && chmod 700 /root/install.sh && bash install.sh

```

## 配置文件

安装完成后，配置文件位于root目录下。

## 特别感谢

特别感谢以下项目的作者和贡献者：

- [Xray Install](https://github.com/xtls/Xray-core)
- [NaiveProxy](https://github.com/klzgrad/naiveproxy)







