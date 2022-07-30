# async-rdma实验手册

本手册将向大家介绍如何使用async-rdma建立双端连接、管理内存和进行数据操作。

## 1. 建立连接

### 1.1 传输服务类型

传输服务类型描述了如何传输数据，传输什么样的数据以及传输的可靠性等内容。
Async-rdma目前主要支持的类型是稳定连接(Reliable Connection, RC)。
该类型能够保障数据的交付，数据顺序，错误恢复等，例如遇到响应超时或丢包时自动进行重试。
只有当发生不可恢复错误，或超过用户设定的重试次数时才返回错误。

若对其他传输服务类型有需求欢迎提issue、pr，一起参与贡献。

### 1.2 建立可靠连接

Async-rdma默认通过Socket传输双端建立稳定连接所需的元数据。
当双端建立连接后Socket连接会被弃用，后续的所有数据通过RDMA方式传输。
下面开始实验。

在环境初始化完成并克隆项目后进入项目的`/examples`目录。
新建用于实验的`my_server.rs`, `my_client.rs`文件。
调用`RdmaBuilder::default().listen()`方法并指定地址即可，配置按默认即可，有兴趣可尝试修改配置后再调用`listen`。

```rust
// Server
#[tokio::main]
async fn main() {
    println!("server start");
    let rdma = RdmaBuilder::default()
        .listen("localhost:5555")
        .await
        .unwrap();
    println!("accepted");
}
```

客户端使用`connect()`连接服务端，需要填入的参数是服务端地址，其余参数同上使用默认值。

```rust
// Client
#[tokio::main]
async fn main() {
    println!("client start");
    let rdma = RdmaBuilder::default()
        .connect("localhost:5555")
        .await
        .unwrap();
    println!("connected");
}
```

## 2. 内存管理

为提高性能，RDMA所用内存需要绕过内核的管理，由用户态或者网卡直接进行读写，因此需要先向内核进行注册。
在向远端内存直接写入或读取数据时需要远端内存的元数据，因此需要远端先注册内存后将元数据发到本端。
本库对以上提到的本地内存和远端内存注册和操作过程进行了包装和简化。
下面通过实验认识一下内存管理相关API。

### 2.1 本地内存

对本地内存进行的管理主要有申请、发送、接收和读写。

* 申请
申请本地内存的接口是`alloc_local_mr()`，入参是所需内存的layout,可以通过`Layout::new::<T>()`获得。
申请得到的`LocalMr`简称lmr，即Local Memory Region。
* 发送
调用接口`send_local_mr()`可以将lmr的元数据发送到远端，以便远端对其进行RDMA读写操作。
* 接收
调用接口`receive_local_mr()`可以接收由远端发来的lmr的元数据。
该接口的应用场景场景是：远端通过Async-rdma框架的内存管理器申请了本地内存后，对其进行RDMA读写。
远端在读写完成后需要告知本端哪块内存被操作完成，本端才能感知对端的操作，并进行读数据等操作。
* 读写
在申请完内存后要对其中的数据进行读写。
使用`as_slice()`和`as_mut_slice()`方法可分别获得lmr的不可变和可变切片，再通过`read()`和`write()`方法读写数据。

```rust
// 申请8字节本地内存
let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8;8]>())?;

// 将该lmr元数据发送至远端，随后远端可对其进行读写
rdma.send_local_mr(lmr).await?;

// 接收远端发来的本地mr元数据
let lmr = rdma.receive_local_mr().await?;

// 向其中写入数据
let _num = lmr.as_mut_slice().write(&[1_u8;8])?;
```

### 2.2 远端内存

与本地内存的管理方法类似，对远端内存的管理也有申请、发送和接收。
远端内存无法在本地进行读写，而是需要通过RDMA操作进行读写，将在下一节中介绍。

* 申请
申请远端内存的接口是`request_remote_mr()`，入参是所需内存的layout,可以通过`Layout::new::<T>()`获得。
申请得到的`RemoteMr`简称rmr，即Remote Memory Region,本质是描述远端内存的元数据。
* 发送
调用接口`send_remote_mr()`可以将rmr的元数据发送到远端，与2.1中的`receive_local_mr()`配合(结对)使用。
* 接收
调用接口`receive_remote_mr()`可以接收由远端发来的rmr的元数据，随后可对其进行RDMA读写操作。
与2.1中的`send_local_mr()`配合(结对)使用。

```rust
// 申请远端内存
let mut rmr = rdma.request_remote_mr(Layout::new::<[u8;8]>()).await?;

// 发送远端内存元数据
rdma.send_remote_mr(rmr).await?;

// 接收远端发来的内存元数据
let rmr = rdma.receive_remote_mr().await.unwrap();
```

### 2.3 内存切片

有时我们需要对本地或远端RDMA内存的一部分进行操作，也就是切片操作。
我们可以对lmr或rmr使用`get()`或`get_mut()`方法获取其可变或不可变切片，并对切片进行本地读写或RDMA读写。

```rust
// 向lmr的后半部分写入数据
let _num = lmr.get_mut(4..8).unwrap().as_mut_slice().write(&[2_u8;4])?;

// 将lmr中后半部分数据写入到远端内存rmr中
rdma.write(&lmr.get(4..8).unwrap(), &mut rmr.get_mut(4..8).unwrap()).await?;
```

## 3. RDMA操作

RDMA操作可以分为两类，一类需要远端感知，即双端操作，一端需要receive，另一端的send才能成功；
另一类不需要远端感知，即单端操作，一端将内存中的数据准备好后，另一端可以直接对其进行读写。

双端操作中，如果一端send而另一端没有recv则会导致操作失败；
单端操作中由于一端可以在另一端不感知的情况下对其内存进行读写，因此两端操作的同步需要保障。
Async-rdma默认接管了底层send/recv通道，避免了双端操作失误导致的操作失败；
同时还提供了第二节中提到的双端内存管理接口，用以保障单端操作的同步。

### 3.1 双端操作

双端操作中需要一端执行接收操作，另一端执行发送操作，使用的接口分别是`receive()`,`send()`.
还可以在发送或接收数据时附带一个32位立即数，接口分别是`receive_with_imm()`,`send_with_imm()`.

```rust
// 接收对端发来的数据
let lmr = rdma.receive().await?;

// 向远端发送lmr中的数据
rdma.send(&lmr).await?;

// 接收对端发来的数据和立即数
let (lmr, imm) = rdma.receive_with_imm().await?;

// 向远端发送lmr中的数据并附带一个立即数
rdma.send_with_imm(&lmr, 1_u32).await?;
```

### 3.2 单端操作

当一端获取了对端的内存元数据后，即可向该内存发起单端操作，即对端不感知的操作。
单端操作是最具RDMA特色的操作，具有最好的性能,使用的接口是`read()`,`write()`。
RDMA WRITE操作还可以附带一个32位立即数，接口是`write_with_imm()`。
由于对端不感知RDMA WRITE操作，因此需要专门接收立即数的接口,`receive_write_imm()`。

```rust
// 对远端内存进行RDMA READ操作，将内容读取到lmr
rdma.read(&mut lmr, &rmr).await?;

// 对远端内存进行RDMA WRITE操作, 将lmr中数据写入到远端内存rmr中
rdma.write(&lmr, &mut rmr).await?;

// 对远端内存进行RDMA WRITE操作, 将lmr中数据写入到远端内存rmr中，并附带一个32位立即数
rdma.write_with_imm(
    &lmr.get(4..8).unwrap(),
    &mut rmr.get_mut(4..8).unwrap(),
    4_u32,
)
.await?;

// 接收对端执行RDMA WRITE时附带的立即数
let imm = rdma.receive_write_imm().await?;
```

## 4. 综合实验

接下来将上述的建立连接、内存管理和数据操作接口结合起来进行RDMA实验。
首先参考1.2中代码建立连接，获得rdma变量，后续的操作围绕其展开。

### 4.1 send/recv

模拟客户端向服务端发送数据的场景。
分别在客户端和服务器的代码文件中添加如下函数，并在主函数中调用。

客户端：

```rust
/// 向服务端发送数据
async fn send_data_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向lmr中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 向远端发送lmr中的数据
    rdma.send(&lmr).await?;
    Ok(())
}
```

服务端：

```rust
/// 接收客户端发来的数据
async fn receive_data_from_client(rdma: &Rdma) -> io::Result<()> {
    // 接收对端发来的数据
    let lmr = rdma.receive().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [1_u8; 8]);
    Ok(())
}
```

### 4.2 send/recv_with_imm

模拟客户端向服务端发送数据并附带立即数的场景，立即数在此处作为发送数据的值供服务端进行判断。
分别在客户端和服务器的代码文件中添加如下函数，并在主函数中调用。

客户端：

```rust
/// 向服务端发送数据和立即数
async fn send_data_with_imm_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向lmr中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 向远端发送lmr中的数据和一个立即数
    rdma.send_with_imm(&lmr, 1_u32).await?;
    Ok(())
}
```

服务端：

```rust
/// 接收客户端发来的数据和立即数
async fn receive_data_with_imm_from_client(rdma: &Rdma) -> io::Result<()> {
    // 接收对端发来的数据和立即数
    let (lmr, imm) = rdma.receive_with_imm().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [imm.unwrap().cast(); 8]);
    Ok(())
}
```

### 4.3 read

客户端向本地内存写入数据后，将内存元数据发送至服务端后被服务端通过RDMA READ读取
分别在客户端和服务器的代码文件中添加如下函数，并在主函数中调用。

客户端：

```rust
/// 向本地内存写入数据后将元数据发送至服务端等待被读取
async fn send_lmr_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [0_u8; 8]);

    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [1_u8; 8]);

    // 向其部分写入数据
    let _num = lmr
        .get_mut(4..8)
        .unwrap()
        .as_mut_slice()
        .write(&[2_u8; 4])?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [[1_u8; 4], [2_u8; 4]].concat());

    // 将该lmr元数据发送至远端，随后远端可对其进行读写
    rdma.send_local_mr(lmr).await?;
    Ok(())
}
```

服务端：

```rust
/// 读取远端mr中的数据
async fn read_rmr_from_client(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 接收远端发来的内存元数据
    let rmr = rdma.receive_remote_mr().await?;
    // 对远端内存进行RDMA READ操作，将内容读取到lmr
    rdma.read(&mut lmr, &rmr).await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[1_u8; 4], [2_u8; 4]].concat());
    Ok(())
}
```

### 4.4 write

客户端申请远端内存并向其中写入数据后将元数据发给服务端，服务端收到后读取数据。
分别在客户端和服务器的代码文件中添加如下函数，并在主函数中调用。

客户端：

```rust
/// 申请远端内存并向其写入数据
async fn request_then_write(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节远端内存
    let mut rmr = rdma.request_remote_mr(Layout::new::<[u8; 8]>()).await?;
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 将lmr中后半部分数据写入到远端内存rmr中
    rdma.write(&lmr.get(4..8).unwrap(), &mut rmr.get_mut(4..8)?)
        .await?;
    // 发送远端内存元数据
    rdma.send_remote_mr(rmr).await?;
    Ok(())
}
```

服务端：

```rust
/// 接收被远端写入过数据的本地mr
async fn receive_mr_after_being_written(rdma: &Rdma) -> io::Result<()> {
    // 接收远端发来的本地mr元数据
    let lmr = rdma.receive_local_mr().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[0_u8; 4], [1_u8; 4]].concat());
    Ok(())
}
```

### 4.5 wirte_with_imm

客户端申请远端内存并向其中写入数据后将元数据发给服务端，并附带发送一个立即数，将该立即数作为不同数据的分界点。
服务端收到后读取数据，并将立即数作为分界点使用。
分别在客户端和服务器的代码文件中添加如下函数，并在主函数中调用。

客户端：

```rust
/// 申请远端内存并向其写入数据，附带发送一个立即数
async fn request_then_write_with_imm(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节远端内存
    let mut rmr = rdma.request_remote_mr(Layout::new::<[u8; 8]>()).await?;
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 将lmr中后半部分数据写入到远端内存rmr中
    // 此处将立即数表示不同数据的分界点
    rdma.write_with_imm(
        &lmr.get(4..8).unwrap(),
        &mut rmr.get_mut(4..8).unwrap(),
        4_u32,
    )
    .await?;
    // 发送远端内存元数据
    rdma.send_remote_mr(rmr).await?;
    Ok(())
}
```

服务端：

```rust
/// 接收被远端写入过数据的本地mr和立即数
async fn receive_mr_after_being_written_with_imm(rdma: &Rdma) -> io::Result<()> {
    // 接收立即数
    let imm = rdma.receive_write_imm().await?;
    // 接收远端发来的本地mr元数据
    let lmr = rdma.receive_local_mr().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[0_u8; 4], [1_u8; 4]].concat());
    // 在此将立即数作为不同数据的分界线
    // RC 支持的消息大小是0~2^32字节因此我们可以使用 u32 as usize
    assert_ne!(data[imm.wrapping_sub(1) as usize], data[imm as usize]);
    Ok(())
}
```

### 4.6 完整代码

以下是客户端和服务端完整代码，在两个终端中运行如下命令尝试上述功能。
首先启动服务端：`cargo run --example my_server`
随后启动客户端：`cargo run --example my_client`

客户端：

```rust
use async_rdma::{LocalMrReadAccess, LocalMrWriteAccess, Rdma, RdmaBuilder};
use std::{
    alloc::Layout,
    io::{self, Write},
};

/// 向服务端发送数据
async fn send_data_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向lmr中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 向远端发送lmr中的数据
    rdma.send(&lmr).await?;
    Ok(())
}

/// 向服务端发送数据和立即数
async fn send_data_with_imm_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向lmr中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 向远端发送lmr中的数据和一个立即数
    rdma.send_with_imm(&lmr, 1_u32).await?;
    Ok(())
}

/// 向本地内存写入数据后将元数据发送至服务端等待被读取
async fn send_lmr_to_server(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [0_u8; 8]);

    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [1_u8; 8]);

    // 向其部分写入数据
    let _num = lmr
        .get_mut(4..8)
        .unwrap()
        .as_mut_slice()
        .write(&[2_u8; 4])?;
    println!("{:?}", *lmr.as_slice());
    assert_eq!(*lmr.as_slice(), [[1_u8; 4], [2_u8; 4]].concat());

    // 将该lmr元数据发送至远端，随后远端可对其进行读写
    rdma.send_local_mr(lmr).await?;
    Ok(())
}

/// 申请远端内存并向其写入数据
async fn request_then_write(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节远端内存
    let mut rmr = rdma.request_remote_mr(Layout::new::<[u8; 8]>()).await?;
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 将lmr中后半部分数据写入到远端内存rmr中
    rdma.write(&lmr.get(4..8).unwrap(), &mut rmr.get_mut(4..8).unwrap())
        .await?;
    // 发送远端内存元数据
    rdma.send_remote_mr(rmr).await?;
    Ok(())
}

/// 申请远端内存并向其写入数据，附带发送一个立即数
async fn request_then_write_with_imm(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节远端内存
    let mut rmr = rdma.request_remote_mr(Layout::new::<[u8; 8]>()).await?;
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 向其中写入数据
    let _num = lmr.as_mut_slice().write(&[1_u8; 8])?;
    // 将lmr中后半部分数据写入到远端内存rmr中
    // 此处将立即数表示不同数据的分界点
    rdma.write_with_imm(
        &lmr.get(4..8).unwrap(),
        &mut rmr.get_mut(4..8).unwrap(),
        4_u32,
    )
    .await?;
    // 发送远端内存元数据
    rdma.send_remote_mr(rmr).await?;
    Ok(())
}

#[tokio::main]
async fn main() {
    println!("client start");
    let rdma = RdmaBuilder::default()
        .connect("localhost:5555")
        .await
        .unwrap();
    println!("connected");
    send_data_to_server(&rdma).await.unwrap();
    send_data_with_imm_to_server(&rdma).await.unwrap();
    send_lmr_to_server(&rdma).await.unwrap();
    request_then_write(&rdma).await.unwrap();
    request_then_write_with_imm(&rdma).await.unwrap();
    println!("client done");
}

```

服务端：

```rust
use async_rdma::{LocalMrReadAccess, Rdma, RdmaBuilder};
use clippy_utilities::Cast;
use std::{alloc::Layout, io};

/// 接收客户端发来的数据
async fn receive_data_from_client(rdma: &Rdma) -> io::Result<()> {
    // 接收对端发来的数据
    let lmr = rdma.receive().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [1_u8; 8]);
    Ok(())
}

/// 接收客户端发来的数据和立即数
async fn receive_data_with_imm_from_client(rdma: &Rdma) -> io::Result<()> {
    // 接收对端发来的数据和立即数
    let (lmr, imm) = rdma.receive_with_imm().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [imm.unwrap().cast(); 8]);
    Ok(())
}

/// 读取远端mr中的数据
async fn read_rmr_from_client(rdma: &Rdma) -> io::Result<()> {
    // 申请8字节本地内存
    let mut lmr = rdma.alloc_local_mr(Layout::new::<[u8; 8]>())?;
    // 接收远端发来的内存元数据
    let rmr = rdma.receive_remote_mr().await?;
    // 对远端内存进行RDMA READ操作，将内容读取到lmr
    rdma.read(&mut lmr, &rmr).await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[1_u8; 4], [2_u8; 4]].concat());
    Ok(())
}

/// 接收被远端写入过数据的本地mr
async fn receive_mr_after_being_written(rdma: &Rdma) -> io::Result<()> {
    // 接收远端发来的本地mr元数据
    let lmr = rdma.receive_local_mr().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[0_u8; 4], [1_u8; 4]].concat());
    Ok(())
}

/// 接收被远端写入过数据的本地mr和立即数
async fn receive_mr_after_being_written_with_imm(rdma: &Rdma) -> io::Result<()> {
    // 接收立即数
    let imm = rdma.receive_write_imm().await?;
    // 接收远端发来的本地mr元数据
    let lmr = rdma.receive_local_mr().await?;
    let data = *lmr.as_slice();
    println!("{:?}", data);
    assert_eq!(data, [[0_u8; 4], [1_u8; 4]].concat());
    // 在此将立即数作为不同数据的分界线
    // RC 支持的消息大小是0~2^32字节因此我们可以使用 u32 as usize
    assert_ne!(data[imm.wrapping_sub(1) as usize], data[imm as usize]);
    Ok(())
}

#[tokio::main]
async fn main() {
    println!("server start");
    let rdma = RdmaBuilder::default()
        .listen("localhost:5555")
        .await
        .unwrap();
    println!("accepted");
    receive_data_from_client(&rdma).await.unwrap();
    receive_data_with_imm_from_client(&rdma).await.unwrap();
    read_rmr_from_client(&rdma).await.unwrap();
    receive_mr_after_being_written(&rdma).await.unwrap();
    receive_mr_after_being_written_with_imm(&rdma)
        .await
        .unwrap();
    println!("server done");
}

```

### 4.7 进阶尝试

若大家在尝试完上述内容后还有时间，可以任选以下任务尝试，还可以作为demo给社区提PR~

1. 编写一个RDMA READ，WRITE 或 SEND 操作的带宽/延迟测试。

    配置好的环境中已有带宽测试程序，在命令行输入`ib_read_bw`，`ib_write_bw`或`ib_send_bw`就可以进行尝试。

    以read为例，开两个终端，分别运行:

    `ib_read_bw`

    `ib_read_bw localhost`

    可以参考该测试程序实现一个简化版的测试demo，具体代码可参考[仓库](https://github.com/linux-rdma/perftest/tree/master)。

2. 编写一个利用任意RDMA操作传输文件或结构体的demo。

3. 您的工作中有什么可以用RDMA加速的场景？写个demo吧！
