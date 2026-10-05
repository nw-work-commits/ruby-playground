# 全アプリのテストを自作 MiniSpec でまとめて実行する:  ruby run_specs.rb
ENV["QUIET"] = "1"
Dir[File.join(__dir__, "*/spec/*_spec.rb")].sort.each { require _1 }
