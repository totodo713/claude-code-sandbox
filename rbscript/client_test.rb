require "net/http"
require "uri"
require "json"

def test_public_api
  # インターネット上のテスト用API（echoサービス）
  url = "https://httpbin.org/get"

  # テストとして、APIに送る適当なクエリパラメータ
  params = { "message" => "Hello bundler!", "status" => "success" }

  puts "〇 インターネット上のAPIに接続中..."

  uri = URI(url)
  uri.query = URI.encode_www_form(params)

  begin
    # GETリクエストを送信
    response = Net::HTTP.get_response(uri)

    # ステータスコードが200（成功）かチェック
    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code} #{response.message}"
    end

    # レスポンスのJSONを解析
    data = JSON.parse(response.body)

    puts "\n✅ 接続成功！サーバーから返ってきたデータ:"
    puts "あなたのIPアドレス: #{data['origin']}"
    puts "送信したパラメータ: #{data['args']}"
    puts "//受信データ: #{data}"
  rescue => e
    puts "❌ 通信エラーが発生しました: #{e.message}"
  end
end

test_public_api if __FILE__ == $PROGRAM_NAME
