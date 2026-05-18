import axios from 'axios';

async function testPublicApi() {
    // インターネット上のテスト用API（echoサービス）
    const url = 'https://httpbin.org/get';

    // テストとして、APIに送る適当なクエリパラメータ
    const params = {
        message: 'Hello pnpm!',
        status: 'success'
    };

    console.log('○ インターネット上のAPIに接続中...');

    try {
        // GETリクエストを送信
        const response = await axios.get(url, { params });

        // レスポンスのデータを取得
        const data = response.data;

        console.log('\n✅ 接続成功！サーバーから返ってきたデータ:');
        console.log(`あなたのIPアドレス: ${data.origin}`);
        console.log('送信したパラメータ:', data.args);
        console.log('受信データ:', data);

    } catch (error) {
        console.error(`❌ 通信エラーが発生しました: ${error.message}`);
    }
}

testPublicApi();
