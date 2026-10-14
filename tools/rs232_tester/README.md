# RS232 快速排障工具

一个独立 Python 脚本，支持 Linux、Windows、macOS。需要 Python 3.8+ 和 `pyserial`，无需运行本项目的其他服务。

## 安装与启动

将整个 `tools/rs232_tester` 文件夹复制到测试电脑或边缘 Linux 设备，进入该文件夹：

```bash
python3 -m pip install -r requirements.txt
python3 rs232_test.py
```

不带参数会进入中文菜单。默认 **9600、8 数据位、无校验、1 停止位、无流控（9600 8N1）**；菜单 `9` 可以修改参数、文本编码和日志路径。Windows 的命令也可使用 `py` 替代 `python3`。

列出当前串口：

```bash
python3 rs232_test.py ports
```

常见路径：Linux `/dev/ttyUSB0`、`/dev/ttyUSB1`、板载 `/dev/ttyS0` 或 `/dev/ttyAMA0`；Windows `COM3`；macOS `/dev/cu.usbserial-xxx`。下面命令中的路径只是示例，需按实际输出替换。

## 建议按此顺序排查

### 1. 单独验证两根 USB 转 RS232 线

先拔掉外接设备。在一根转接线的 **RS232 DB9 端短接 2、3 脚**，USB 端接电脑：

```bash
python3 rs232_test.py loopback -p /dev/ttyUSB0 -b 9600
```

脚本发送随机前缀和二进制测试数据，逐字节检查收到的内容，默认 5 轮。每轮均 `PASS` 说明这根转接线在当前参数下能发送、接收；再以相同方法测试另一根。

改波特率或增加测试量：

```bash
python3 rs232_test.py loopback -p /dev/ttyUSB0 -b 115200 --count 100 --size 272 --log cable_a.jsonl
```

按接头上标注的针脚编号操作，公头与母头从正面看位置会镜像。只连接确认过的信号脚；不要根据外观猜针脚。这里针对真正的 RS232，不适用于把 TTL 串口当作 RS232 连接。

### 2. 两根转接线互测

两根线的 USB 都插到同一电脑。常见 USB 转 RS232 为 DTE 接口，其 DB9 端用空调制解调器线（null modem / 交叉线）连接：

| A 端 | B 端 |
| --- | --- |
| 2（RX） | 3（TX） |
| 3（TX） | 2（RX） |
| 5（GND） | 5（GND） |

```bash
python3 rs232_test.py pair --port-a /dev/ttyUSB0 --port-b /dev/ttyUSB1 -b 9600
```

脚本轮流验证 A→B 和 B→A，只有两个方向的数据全部一致才通过。**公头和母头能插在一起，不代表 TX/RX 线序正确**；直连是否成立取决于两端是 DTE 还是 DCE。实际设备以厂家针脚定义为准，不同接头也不能套用 DB9 编号。

### 3. 单独验证边缘 Linux 的 RS232 口

在边缘设备上停止占用目标串口的业务程序。确认板载端口确实为 RS232；有些板子的 UART 引脚是 TTL 电平，需要 RS232 电平转换模块。

如果板载口为标准 RS232 DB9，可先短接其 2、3 脚并运行：

```bash
python3 rs232_test.py loopback -p /dev/ttyS0 -b 9600
```

随后取消短接，将已验证的 USB 转接线接入边缘 Linux 的 USB 口，再按双方针脚定义连接到板载 RS232 口，做双口对测：

```bash
python3 rs232_test.py pair --port-a /dev/ttyS0 --port-b /dev/ttyUSB0 -b 9600
```

若 USB 在另一台电脑上，两边分别运行 `terminal`，在任意一边输入文本，另一边观察 RX：

```bash
python3 rs232_test.py terminal -p /dev/ttyS0 -b 9600
```

另一台电脑把串口改为它自己的 USB 转接线端口。该方法可验证两个方向；单独运行 `send` 不会让对方自动回显。

### 4. 连接真正的设备，使用正确协议查询

已经确认转接线和边缘串口能正常互测后，接回设备，使用设备要求的波特率、校验位、流控、地址和查询指令。

被动监听设备主动上报：

```bash
python3 rs232_test.py listen -p /dev/ttyUSB0 -b 9600 --duration 30 --log device.jsonl
```

如果设备仅在收到查询后应答，被动监听没有数据是正常的。`send` 示例中的数据须替换为设备实际支持的查询：

```bash
python3 rs232_test.py send -p /dev/ttyUSB0 -b 9600 --hex "01 03 00 00 00 02 C4 0B" --timeout 2 --log device.jsonl
python3 rs232_test.py send -p /dev/ttyUSB0 -b 9600 --text "STATUS?" --newline crlf --timeout 2
```

第一条是 **Modbus RTU 从站 1、读保持寄存器 0 起的 2 个寄存器**，只适用于确实支持该地址和寄存器的设备。第二条只是文本格式示例，`STATUS?` 不是通用 RS232 指令。

也可自动生成 Modbus CRC，输入时不要带原 CRC：

```bash
python3 rs232_test.py send -p /dev/ttyUSB0 -b 9600 --hex "01 03 00 00 00 02" --modbus-crc --timeout 2
python3 rs232_test.py crc --hex "01 03 00 00 00 02"
```

CRC 输出应为 `C4 0B`（低字节在前）。工具不会自动解析设备协议，也不会遍历地址或寄存器。

## 其他快捷测试

循环发送，要求收到的字节中包含预期内容：

```bash
python3 rs232_test.py send -p /dev/ttyUSB0 --text "STATUS?" --newline crlf --repeat 5 --interval 1 --expect-text "OK"
```

HEX 预期响应使用 `--expect-hex "01 03 04"`。没有设置预期内容时，收到任何字节仅表示有数据进入串口，可能是本地回显或设备其他上报，不证明协议正确。

交互终端：

```bash
python3 rs232_test.py terminal -p /dev/ttyUSB0 -b 9600 --newline crlf --encoding gbk
```

输入文本后回车发送；输入 `/hex 01 03 00 00 00 02 C4 0B` 发送原始 HEX；`/quit` 退出。`--newline` 只作用于文本，HEX 中的结尾自行写 `0D` / `0A`。

扫描波特率和校验位，默认不发送数据：

```bash
python3 rs232_test.py scan -p /dev/ttyUSB0 --rates 4800 9600 19200 115200 --parities N E O --duration 3
```

如果设备仅响应查询，可在每组参数下发送一条**已确认的读取指令**：

```bash
python3 rs232_test.py scan -p /dev/ttyUSB0 --rates 9600 19200 --parities N E --hex "01 03 00 00 00 02" --modbus-crc --expect-hex "01 03 04" --duration 2
```

扫描表中的字节数和 ASCII 比例是排查线索。二进制协议本来就可能显示乱码；必须结合完整响应、协议校验或已知内容确认参数。扫描会逐组关闭、重开串口，DTR/RTS 可能随之变化。

查看握手信号，或设置 RTS/DTR：

```bash
python3 rs232_test.py signals -p /dev/ttyUSB0 --duration 10
python3 rs232_test.py signals -p /dev/ttyUSB0 --rts on --dtr on
```

部分转接线只有 TX/RX/GND，不支持握手信号；`不支持` 或输入为 `0` 不表示数据线路坏了。默认不启用流控；三线连接通常使用 `--flow none`。只有设备和完整接线确实支持时才使用 `--flow rtscts` / `dsrdtr` / `xonxoff`。测试载荷在 5/6/7 数据位下会限制为对应位数；软件流控下会排除 XON/XOFF 控制字节。

所有串口命令还支持：`--bytesize 7 --parity E --stopbits 1`、`--encoding gbk`、`--log test.jsonl`、`--display-bytes 0`。子命令后加 `--help` 查看参数。

## 如何判断下一步

| 现象 | 优先检查 |
| --- | --- |
| 无法打开串口 | 路径、驱动、系统权限、业务程序/终端是否占用 |
| 某根转接线自己回环失败 | 2/3 脚短接是否正确、参数、转接线和 USB 驱动 |
| 两根各自回环通过，双口互测失败 | 直通/交叉线序、GND、DB9 针脚定义、流控 |
| 双口互测只有单向通过 | 失败方向的 TX→RX 接线、接触情况；交换已验证的转接线缩小范围 |
| USB 转接线正常，板载口回环失败 | 端口映射、板载口电平/模式、针脚定义和串口占用 |
| 与边缘串口互测通过，设备不回复 | 实际设备接线、供电、串口设置、地址、协议、帧结束符及响应超时 |
| 接收到乱码 | 波特率/校验位/数据位、电平和接地；若是二进制协议，优先看 HEX |

Linux 端可用这些命令核对路径、驱动和占用：

```bash
ls -l /dev/ttyUSB* /dev/serial/by-id/
dmesg | tail -n 40
id
lsof /dev/ttyUSB0
fuser /dev/ttyUSB0
```

有些命令需额外安装或管理员权限。若权限被拒绝，核对串口设备的所属组；常见 Debian/Ubuntu 使用 `dialout`。管理员可将当前用户加入该组，重新登录后生效：

```bash
sudo usermod -aG dialout "$USER"
```

板载串口还可能作为系统控制台或 `serial-getty` 使用，需根据该设备的系统配置解除占用；不要在未确认用途时直接停用系统服务。USB 重新插拔后 `/dev/ttyUSB0` 编号可能变化，Linux 可优先使用 `/dev/serial/by-id/` 的稳定路径。

## 日志、退出码与软件验证

终端按接收分块显示时间、方向、长度、HEX 和文本。这些分块不是协议帧，文本字符也可能跨块；HEX 是实际收到的字节。`--log` 会追加 JSONL 日志，保存完整收发内容，即使终端显示被截短。它记录软件观察到的数据，不测量 RS232 电压或物理线路时序。

退出码：`0` 测试通过/命令正常完成，`1` 数据对比失败或响应窗口内无预期数据，`2` 配置或串口操作错误，`130` 用户中断。监听无数据仍正常退出。

不用硬件即可验证脚本的内部回环路径：

```bash
python3 rs232_test.py loopback -p loop:// --count 2
python3 -m unittest discover -s tests -v
```

`loop://` 是 pyserial 软件回环，只检查脚本，不检验 USB 转接线、驱动、板载串口或实物接线。
