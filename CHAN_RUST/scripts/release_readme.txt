缠论 K 线（chan_kline）发布包

怎么用
1. 解压整个文件夹，不要只拷贝其中一个 exe / 可执行文件。
2. Windows：双击 chan_kline.exe
   Linux：在终端执行 ./chan_kline
3. 行情数据在同目录 a_Data（默认股票 002003）。也可设环境变量 CHAN_DATA_ROOT 指向别的数据目录。

注意
- dll / so 必须和主程序在同一套目录结构里，单独拖走 exe 会打不开。
- Windows 若提示缺少运行库：安装 Microsoft Visual C++ Redistributable（x64）。
- Linux 需要 GTK3 桌面环境（常见发行版一般已有）。
