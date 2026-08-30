缠论 K 线（chan_kline）发布包

怎么用
1. 解压整个文件夹，不要只拷贝其中一个 exe。
2. 双击 chan_kline.exe 启动。
3. 行情数据在同目录 a_Data（默认股票 002003）。也可设环境变量 CHAN_DATA_ROOT 指向别的数据目录。

注意
- chan_ffi.dll 必须和 chan_kline.exe 在同一目录，单独拖走 exe 会打不开。
- Windows 若提示缺少运行库：安装 Microsoft Visual C++ Redistributable（x64）。
