# frozen_string_literal: true

#
# Copyright 2013 whiteleaf. All rights reserved.
#

require_relative "../narou"
require_relative "../mailer"

module Command
  class Mail < CommandBase
    def self.oneline_help
      "変換したEPUB/MOBIをメールで送信します"
    end

    def initialize
      super("[<target1> ...] [options]")
      @opt.separator <<-EOS

  ・主にSend to Kindleを使うためのコマンドです。
  ・<target>で指定した小説の電子書籍データメールで送信します。
  ・<target>を省略した場合、新着があった小説を全て送信します。
  ・メールの送信設定は、#{Mailer::SETTING_FILE}ファイルを編集します。
    (初めてコマンドを使うときに自動で作成されます)
  ・<target>にhotentryを指定した場合、最新のhotnetryを送信します

  Examples:
    narou mail 6         # 新着関係なくメール(送信済みフラグは立つ)

    narou update
    narou mail           # updateで新着があった小説を全てメール

    narou mail --force   # 凍結済以外の全ての小説を強制的にメール(使い方に注意)

  Options:
      EOS

      @opt.on("-f", "--force", "全ての小説を強制的に送信") {
        @options["force"] = true
      }
    end

    def execute(argv)
      super
      send_all = false
      device = Narou.get_device
      database = Database.instance
      begin
        mailer = Mailer.create
      rescue Mailer::SettingNotFound
        install_mailer_setting
        return
      rescue Mailer::SettingUncompleteError => e
        stream_io.error e.message
        exit Narou::EXIT_ERROR_CODE
      end
      if argv.empty?
        send_all = true
        database.each_key do |id|
          next if Narou.novel_frozen?(id)
          argv << id
        end
      end
      tagname_to_ids(argv)
      argv.each do |target|
        if target == "hotentry"
          ebook_paths = [Update.get_newest_hotentry_file_path(device)]
          display_target = "hotentry"
        else
          ebook_paths = Narou.get_ebook_file_paths(target, device ? device.ebook_file_ext : ".epub")
          data = Downloader.get_data_by_target(target)
          if send_all && !@options["force"]
            new_arrivals_date = data["new_arrivals_date"] || Time.now
            if data["last_mail_date"] && new_arrivals_date < data["last_mail_date"]
              next   # すでに送信済みなので送信しない
            end
          end
        end
        unless ebook_paths[0]
          stream_io.error "#{target} は存在しません" unless send_all
          next
        end
        unless File.exist?(ebook_paths[0])
          stream_io.error "まだファイル(#{File.basename(ebook_paths[0])})が無いようです" unless send_all
          next
        end
        if target == "hotentry"
          id = "hotentry"
        else
          id = data["id"]
          title = data["title"]
          display_target = "ID:#{id}　#{TermColorLight.escape(title)}"
        end
        stream_io.puts "<bold><green>#{display_target}</green></bold>".termcolor
        ext = device ? device.ebook_file_ext : ".epub"
        case deliver_novel(mailer, id, ebook_paths, hotentry: target == "hotentry") { Narou.get_ebook_file_paths(target, ext) }
        when :sent
          database[id]["last_mail_date"] = Time.now if target != "hotentry"
        when :too_large
          # 容量だけの問題なので、この作品は飛ばして次の作品を送る（送信記録は更新しない）
          stream_io.error mailer.error_message
          stream_io.puts "#{display_target} は送信を飛ばしました"
        else
          stream_io.error mailer.error_message
          exit Narou::EXIT_ERROR_CODE # next しても次も失敗する可能性が高いのでここで終了
        end
      end
    rescue Interrupt
      stream_io.puts "メール送信を中断しました"
      exit Narou::EXIT_INTERRUPT
    ensure
      database.save_database if database
    end

    #
    # 1 作品分の電子書籍を送る。:sent / :too_large / :error を返す
    #
    # 画像を縮小してもメールの上限を超えたときは、その作品の挿絵を無効にして（setting.ini の
    # enable_illust = false）変換し直し、1 回だけ送り直す。設定は残るので、次からは最初から挿絵なしで変換される。
    # 変換し直した後の電子書籍のパスはブロックで受け取る
    #
    def deliver_novel(mailer, id, ebook_paths, hotentry: false)
      result = send_ebooks(mailer, id, ebook_paths)
      return result unless result == :too_large && !hotentry
      stream_io.puts "画像を縮小してもメールの上限を超えるため、挿絵を無効にして変換し直します"
      return :too_large unless disable_illust_and_convert(id)
      send_ebooks(mailer, id, yield)
    end

    def send_ebooks(mailer, id, ebook_paths)
      ebook_paths.each do |ebook_path|
        stream_io.print "メールを送信しています"
        exit_mail = false
        mail_result = nil
        Thread.new do
          mail_result = mailer.send(id, File.basename(ebook_path), ebook_path)
          exit_mail = true
        end
        until exit_mail
          stream_io.print "."
          sleep(0.5)
        end
        stream_io.puts
        return(mailer.too_large? ? :too_large : :error) unless mail_result
        stream_io.puts File.basename(ebook_path) + " をメールで送信しました"
      end
      :sent
    end

    # 挿絵を無効にして変換し直す。すでに無効だった、または変換に失敗したときは false
    def disable_illust_and_convert(id)
      return false if NovelSetting.load(id)["enable_illust"] == false
      setting = NovelSetting.create(id, true, true)
      setting["enable_illust"] = false
      setting.save_settings
      stream_io.puts "setting.ini の enable_illust を false にしました"
      Convert.execute!(id.to_s, "--no-open", io: stream_io, sync: true) == 0
    end

    def install_mailer_setting
      setting_file_path = File.join(Narou.preset_dir, Mailer::SETTING_FILE)
      install_path = File.join(Narou.root_dir, Mailer::SETTING_FILE)
      FileUtils.cp(setting_file_path, install_path)
      alter_database_add_column_last_mail_date
      stream_io.puts <<~MSG
        created #{install_path}
        メールの設定用ファイルを作成しました。設定ファイルを書き換えることで mail コマンドが有効になります。
        注意：次回以降のupdateで新着があった場合に送信可能フラグが立ちます
      MSG
      unless Narou.web?
        Helper.open_directory(Narou.root_dir, "設定ファイルがあるフォルダを開きますか")
      end
    end

    def alter_database_add_column_last_mail_date
      database = Database.instance
      database.each_value do |data|
        data["last_mail_date"] ||= Time.now
      end
      database.save_database
    end
  end
end
