# ブラウザの Ruby には socket が無い (ネットワークの待ち受けはできない)。
# MiniWeb が socket を使うのはサーバーとして待ち受けるとき (Server#start の TCPServer) だけで、
# ブラウザ版はそこを通らない。読み込みで止まらないよう、代わりにこのファイルを読ませる。
class TCPServer
  def initialize(*)
    raise NotImplementedError, "ブラウザの中ではサーバーとして待ち受けできません"
  end
end
