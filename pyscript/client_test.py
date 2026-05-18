import httpx


def test_public_api():
    # インターネット上のテスト用API（echoサービス）
    url = "https://httpbin.org/get"

    # テストとして、APIに送る適当なクエリパラメータ
    params = {"message": "Hello uv!", "status": "success"}

    print("〇 インターネット上のAPIに接続中...")

    try:
        # GETリクエストを送信
        response = httpx.get(url, params=params)

        # ステータスコードが200（成功）かチェック
        response.raise_for_status()

        # レスポンスのJSONを解析
        data = response.json()

        print("\n✅ 接続成功！サーバーから返ってきたデータ:")
        print(f"あなたのIPアドレス: {data.get('origin')}")
        print(f"送信したパラメータ: {data.get('args')}")
        print(f"//受信データ: {data}")

    except httpx.HTTPError as e:
        print(f"❌ 通信エラーが発生しました: {e}")


if __name__ == "__main__":
    test_public_api()
