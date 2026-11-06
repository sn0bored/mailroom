namespace :mailroom do
  namespace :postmark do
    desc "Point the Postmark server's inbound webhook at this Mailroom and learn the inbound address"
    task configure: :environment do
      result = PostmarkSetup.new.configure!
      puts "Postmark server #{result[:server_id]} (#{result[:server_name]}) now posts inbound mail to #{result[:public_host]}."
      puts "Inbound address for registrar forwarders: #{result[:inbound_address]}"
    end

    desc "Ask Postmark to retry every inbound message it gave up on"
    task retry_failed: :environment do
      result = PostmarkSetup.new.retry_failed!
      puts "Postmark failed inbound messages: #{result[:failed]}, retried: #{result[:retried]}"
    end
  end

  namespace :owner do
    desc "Create the owner account (EMAIL and PASSWORD from the environment)"
    task create: :environment do
      email, password = ENV.fetch("EMAIL"), ENV.fetch("PASSWORD")
      user = User.find_or_initialize_by(email_address: email)
      user.password = password
      user.save!
      puts "owner #{user.email_address} ready"
    end
  end

  namespace :api_key do
    desc "Create an API key (NAME, SCOPES comma separated, DOMAINS comma separated optional); prints the token once"
    task create: :environment do
      record, plaintext = ApiKey.generate(
        name: ENV.fetch("NAME"),
        scopes: ENV.fetch("SCOPES").split(",").map(&:strip),
        allowed_from_domains: ENV.fetch("DOMAINS", "").split(",").map(&:strip).reject(&:empty?)
      )
      puts "api key #{record.id} (#{record.name}) scopes=#{record.scopes.join(',')}"
      puts "token (shown once): #{plaintext}"
    end
  end

  namespace :domains do
    desc "Add domains (NAMES comma separated)"
    task add: :environment do
      ENV.fetch("NAMES").split(",").map(&:strip).reject(&:empty?).each do |name|
        domain = Domain.find_or_create_by!(name: name.downcase)
        puts "#{domain.name}: probe address #{domain.probe_address}"
        puts "  registrar catch-all: #{domain.catch_all_instruction || 'run mailroom:postmark:configure first'}"
      end
    end
  end

  desc "Back up every database and the raw mail store into MAILROOM_DATA_DIR/backups, keeping the newest 14"
  task backup: :environment do
    data_dir = Mailroom.data_dir
    stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
    target = data_dir.join("backups", stamp)
    FileUtils.mkdir_p(target)
    Dir.glob(data_dir.join("*.sqlite3")).each do |db|
      system("sqlite3", db, ".backup #{target.join(File.basename(db))}") || abort("backup of #{db} failed")
    end
    storage = data_dir.join("storage")
    system("rsync", "-a", "#{storage}/", "#{target.join('storage')}/") if storage.directory?
    keep = 14
    Dir.glob(data_dir.join("backups", "*")).sort.reverse.drop(keep).each { |old| FileUtils.rm_rf(old) }
    puts "backup written to #{target}"
  end
end
