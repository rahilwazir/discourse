
# frozen_string_literal: true

require "mysql2"
require "htmlentities"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Before running this script, paste these lines into your shell,
# then use arrow keys to edit the values
=begin
export DB_HOST="localhost"
export DB_NAME="mybb"
export DB_PW=""
export DB_USER="root"
export TABLE_PREFIX="mybb_"
export BASE="" #
=end

# Call it like this:
#   RAILS_ENV=production ruby script/import_scripts/mybb.rb
class ImportScripts::MyBB < ImportScripts::Base

  DB_HOST ||= ENV['DB_HOST'] || "172.17.0.1"
  DB_NAME ||= ENV['DB_NAME'] || "nzarchitecture"
  DB_PW ||= ENV['DB_PW'] || "root"
  DB_USER ||= ENV['DB_USER'] || "root"
  TABLE_PREFIX ||= ENV['TABLE_PREFIX'] || "mybb_"
  BATCH_SIZE = 1000
  BASE = ""
  QUIET = true
  ATTACHMENT_DIR = '/var/www/discourse/public/uploads/MyBBAttachmentUploads/uploads'

  def initialize
    super

    @old_username_to_new_usernames = {}

    @htmlentities = HTMLEntities.new

    @client = Mysql2::Client.new(
      host: DB_HOST,
      username: DB_USER,
      password: DB_PW,
      database: DB_NAME
    )
  end

  def execute
    SiteSetting.disable_emails = "non-staff"
    import_users
    import_categories
    import_tags
    import_posts
    import_topic_tags
    import_private_messages
    create_permalinks
    suspend_users
    post_process_posts
    import_attachments
  end

  def import_users
    puts '', "creating users"

    total_count = mysql_query("SELECT count(*) count
                                 FROM #{TABLE_PREFIX}users u
                                 JOIN #{TABLE_PREFIX}usergroups g ON g.gid = u.usergroup
                                WHERE g.title != 'Banned';").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT uid id, email email, username, regdate, g.title `group`, uf.fid1, uf.fid2, uf.fid4, uf.fid5, uf.fid6, uf.fid7
           FROM #{TABLE_PREFIX}users u
           JOIN #{TABLE_PREFIX}usergroups g ON g.gid = u.usergroup
           LEFT JOIN #{TABLE_PREFIX}userfields uf ON uf.ufid = u.uid
          WHERE g.title != 'Banned'
          ORDER BY u.uid ASC
          LIMIT #{BATCH_SIZE}
         OFFSET #{offset};")

      break if results.size < 1

      #next if all_records_exist? :users, results.map { |u| u["id"].to_i }
      
      custom_fields = {fid1: 'user_field_6', fid2: 'user_field_5', fid4: 'user_field_2', fid7: 'user_field_1'}

      create_users(results, total: total_count, offset: offset) do |user|
        { id: user['id'],
          email: user['email'],
          name: ((user['fid5'] ||= '') + " " + (user['fid6'] ||= '')),
          username: user['username'],
          created_at: Time.zone.at(user['regdate']),
          moderator: user['group'] == 'Super Moderators',
          admin: user['group'] == 'Administrators',
          #custom_fields: {
          #  user_field_6: user['fid1'],
          #  user_field_5: user['fid2'],
          #  user_field_2: user['fid4'],
          #  user_field_1: user['fid7']
          #},
          post_create_action: proc do |newuser| 

            name = (user['fid5'] ||= '') + " " + (user['fid6'] ||= '')
            puts name
            newuser.name = name
            newuser.save

            if user['fid1'] then
              user_field_name = custom_fields[:fid1]
              user_custom_field = UserCustomField.where(user_id:newuser.id,name:user_field_name).first
  
              if user_custom_field == nil then
                user_custom_field = UserCustomField.create!(user_id: newuser.id, name: user_field_name, value: user['fid1'])
              else
                if user_custom_field.value != user['fid1'] then
                  user_custom_field.value = user['fid1']
                  user_custom_field.save!
                end
              end
            end

            if user['fid2'] then
              user_field_name = custom_fields[:fid2]
              user_custom_field = UserCustomField.where(user_id:newuser.id,name:user_field_name).first
              if user_custom_field == nil then
                user_custom_field = UserCustomField.create!(user_id: newuser.id, name: user_field_name, value: user['fid2'])
              else
                if user_custom_field.value != user['fid2'] then
                  user_custom_field.value = user['fid2']
                  user_custom_field.save!
                end
              end
            end

            if user['fid4'] then
              user_field_name = custom_fields[:fid4]
              user_custom_field = UserCustomField.where(user_id:newuser.id,name:user_field_name).first
              if user_custom_field == nil then
                user_custom_field = UserCustomField.create!(user_id: newuser.id, name: user_field_name, value: user['fid4'])
              else
                if user_custom_field.value != user['fid4'] then
                  user_custom_field.value = user['fid4']
                  user_custom_field.save!
                end
              end
            end

            if user['fid7'] then
              user_field_name = custom_fields[:fid7]
              user_custom_field = UserCustomField.where(user_id:newuser.id,name:user_field_name).first
              if user_custom_field == nil then
                user_custom_field = UserCustomField.create!(user_id: newuser.id, name: user_field_name, value: user['fid7'])
              else
                if user_custom_field.value != user['fid7'] then
                  user_custom_field.value = user['fid7']
                  user_custom_field.save!
                end
              end
            end            
          end
       }  
      end
    end
  end

  def import_categories
    results = mysql_query("
      SELECT fid id, pid parent_id, left(name, 50) name, description
        FROM #{TABLE_PREFIX}forums
    ORDER BY pid ASC, fid ASC
    ")

    create_categories(results) do |row|
      h = { id: row['id'], name: CGI.unescapeHTML(row['name']), description: CGI.unescapeHTML(row['description']) }
      if row['parent_id'].to_i > 0
        h[:parent_category_id] = category_id_from_imported_category_id(row['parent_id'])
      end
      h
    end
  end

  def import_tags
    results = mysql_query("
      SELECT pid id, prefix title
        FROM #{TABLE_PREFIX}threadprefixes
    ")

    create_tags(results) do |row|
      name = tag_name(row['title'])
      h = { id: row['id'], name: name }
      h
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from #{TABLE_PREFIX}posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.pid id,
               p.tid topic_id,
               t.fid category_id,
               t.subject title,
               t.firstpost first_post_id,
               p.uid user_id,
               p.message raw,
               p.dateline post_time
          FROM #{TABLE_PREFIX}posts p,
               #{TABLE_PREFIX}threads t
         WHERE p.tid = t.tid
      ORDER BY p.dateline
         LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ")

      break if results.size < 1

      next if all_records_exist? :posts, results.map { |m| m['id'].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        # If you have imported a phpbb forum to mybb previously there might
        # be a problem with #{TABLE_PREFIX}threads.firstpost. If these ids are wrong
        # the thread cannot be imported to discourse as the topic post is
        # missing. This query retrieves the first_post_id manually. As it
        # will decrease the performance it is commented out by default.
        # m['first_post_id'] = mysql_query("
        #   SELECT   p.pid id,
        #   FROM     #{TABLE_PREFIX}posts p,
        #            #{TABLE_PREFIX}threads t
        #   WHERE    p.tid = #{m['topic_id']} AND t.tid = #{m['topic_id']}
        #   ORDER BY p.dateline
        #   LIMIT    1
        # ").first['id']

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['user_id']) || -1
        mapped[:raw] = process_mybb_post(m['raw'], m['id'])
        mapped[:created_at] = Time.zone.at(m['post_time'])

        if m['id'] == m['first_post_id']
          mapped[:category] = category_id_from_imported_category_id(m['category_id'])
          mapped[:title] = CGI.unescapeHTML(m['title'])
        else
          parent = topic_lookup_from_imported_post_id(m['first_post_id'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m['first_post_id']} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def import_topic_tags
    puts "", "importing topic tags"

    total_count = mysql_query("
      SELECT count(*) count FROM #{TABLE_PREFIX}threads t
        INNER JOIN #{TABLE_PREFIX}threadprefixes tp 
          ON t.prefix = tp.pid
        INNER JOIN #{TABLE_PREFIX}posts p 
          ON t.tid = p.tid
        GROUP BY t.tid, p.pid
    ").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT t.tid topic_id,
               p.pid post_id,
               tp.prefix tag
          FROM #{TABLE_PREFIX}threads t
        INNER JOIN #{TABLE_PREFIX}threadprefixes tp 
          ON t.prefix = tp.pid
        INNER JOIN #{TABLE_PREFIX}posts p 
          ON t.tid = p.tid
        GROUP BY t.tid, p.pid
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ")

      break if results.size < 1

      create_topic_tags(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        tag = tag_name(m['tag'])
        tag_id = Tag.find_by_name(tag).try(:id)

        if tag_id.nil?
          skip = true
        else
          topic_custom_field = TopicCustomField.where(name: "import_id", value: m['post_id']).first

          if topic_custom_field.nil?
            skip = true
          else
            topic_id = topic_custom_field.topic_id

            mapped[:id] = m['topic_id']
            mapped[:topic_id] = topic_id
            mapped[:tag_id] = tag_id
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def import_private_messages
    puts "", "private messages are not implemented"
  end

  def suspend_users
    puts '', "banned users are not implemented"
  end

  # Discourse usernames don't allow spaces
  def convert_username(username, post_id)
    count = 0
    username.gsub!(/\s+/) { |a| count += 1; '_' }
    # Warn on MyBB bug that places post text in the quote line - http://community.mybb.com/thread-180526.html
    if count > 5
      puts "Warning: probably incorrect quote in post #{post_id}"
    end
    username
  end

  # Take an original post id and return the migrated topic id and post number for it
  def post_id_to_post_num_and_topic(quoted_post_id, post_id)
    quoted_post_id_from_imported = post_id_from_imported_post_id(quoted_post_id.to_i)
    if quoted_post_id_from_imported
      begin
        post = Post.find(quoted_post_id_from_imported)
        "post:#{post.post_number}, topic:#{post.topic_id}"
      rescue
        puts "Could not find migrated post #{quoted_post_id_from_imported} quoted by original post #{post_id} as #{quoted_post_id}"
        ""
      end
    else
      puts "Original post #{post_id} quotes nonexistent post #{quoted_post_id}"
      ""
    end
  end

  def process_mybb_post(raw, import_id)
    s = raw.dup

    # convert the quote line
    s.gsub!(/\[quote='([^']+)'.*?pid='(\d+).*?\]/) {
      "[quote=\"#{convert_username($1, import_id)}, " + post_id_to_post_num_and_topic($2, import_id) + '"]'
    }

    # :) is encoded as <!-- s:) --><img src="{SMILIES_PATH}/icon_e_smile.gif" alt=":)" title="Smile" /><!-- s:) -->
    s.gsub!(/<!-- s(\S+) -->(?:.*)<!-- s(?:\S+) -->/, '\1')

    # Some links look like this: <!-- m --><a class="postlink" href="http://www.onegameamonth.com">http://www.onegameamonth.com</a><!-- m -->
    s.gsub!(/<!-- \w --><a(?:.+)href="(\S+)"(?:.*)>(.+)<\/a><!-- \w -->/, '[\2](\1)')

    # Many phpbb bbcode tags have a hash attached to them. Examples:
    #   [url=https&#58;//google&#46;com:1qh1i7ky]click here[/url:1qh1i7ky]
    #   [quote=&quot;cybereality&quot;:b0wtlzex]Some text.[/quote:b0wtlzex]
    s.gsub!(/:(?:\w{8})\]/, ']')

    # Remove mybb video tags.
    s.gsub!(/(^\[video=.*?\])|(\[\/video\]$)/, '')

    s = CGI.unescapeHTML(s)

    # phpBB shortens link text like this, which breaks our markdown processing:
    #   [http://answers.yahoo.com/question/index ... 223AAkkPli](http://answers.yahoo.com/question/index?qid=20070920134223AAkkPli)
    #
    # Work around it for now:
    s.gsub!(/\[http(s)?:\/\/(www\.)?/, '[')

    preprocess_post_raw(s)
  end

  def create_permalinks
    puts '', 'Creating redirects...', ''

    SiteSetting.permalink_normalizations = '/(\\w+)-(\\d+)[-.].*/\\1-\\2.html'
    puts '', 'Users...', ''
    total_users = User.count
    start_time = Time.now
    count = 0
    User.find_each do |u|
      ucf = u.custom_fields
      count += 1
      if ucf && ucf["import_id"] && ucf["import_username"]
        Permalink.create(url: "#{BASE}/user-#{ucf['import_id']}.html", external_url: "/u/#{u.username}") rescue nil
      end
      print_status(count, total_users, start_time)
    end

    puts '', 'Categories...', ''
    total_categories = Category.count
    start_time = Time.now
    count = 0
    Category.find_each do |cat|
      ccf = cat.custom_fields
      count += 1
      next unless id = ccf["import_id"]
      unless QUIET
        puts ("forum-#{id}.html --> /c/#{cat.id}")
      end
      Permalink.create(url: "#{BASE}/forum-#{id}.html", category_id: cat.id) rescue nil
      print_status(count, total_categories, start_time)
    end

    puts '', 'Topics...', ''
    total_posts = Post.count
    start_time = Time.now
    count = 0
    puts '', 'Posts...', ''
    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.pid id,
               p.tid topic_id
          FROM #{TABLE_PREFIX}posts p,
               #{TABLE_PREFIX}threads t
         WHERE p.tid = t.tid
           AND t.firstpost=p.pid
      ORDER BY p.dateline
         LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ")
      break if results.size < 1
      results.each do |post|
        count += 1
        if topic = topic_lookup_from_imported_post_id(post['id'])
          id = post['topic_id']
          Permalink.create(url: "#{BASE}/thread-#{id}.html", topic_id: topic[:topic_id]) rescue nil
          unless QUIET
            puts ("#{BASE}/thread-#{id}.html --> http://localhost:3000/t/#{topic[:topic_id]}")
          end
          print_status(count, total_posts, start_time)
        end
      end
    end
  end

  def post_process_posts
    puts "", "Postprocessing posts..."

    current = 0
    max = Post.count

    Post.find_each do |post|
      begin
        new_raw = postprocess_post_raw(post.raw)
        if new_raw != post.raw
          post.raw = new_raw
          post.save
        end
      rescue PrettyText::JavaScriptError
        nil
      ensure
        print_status(current += 1, max)
      end
    end
  end

  def preprocess_post_raw(raw)
    return "" if raw.blank?

    # decode HTML entities
    raw = @htmlentities.decode(raw)

    # fix whitespaces
    raw = raw.gsub(/(\\r)?\\n/, "\n")
      .gsub("\\t", "\t")

    # [HTML]...[/HTML]
    raw = raw.gsub(/\[html\]/i, "\n```html\n")
      .gsub(/\[\/html\]/i, "\n```\n")

    # [PHP]...[/PHP]
    raw = raw.gsub(/\[php\]/i, "\n```php\n")
      .gsub(/\[\/php\]/i, "\n```\n")

    # [HIGHLIGHT="..."]
    raw = raw.gsub(/\[highlight="?(\w+)"?\]/i) { "\n```#{$1.downcase}\n" }

    # [CODE]...[/CODE]
    # [HIGHLIGHT]...[/HIGHLIGHT]
    raw = raw.gsub(/\[\/?code\]/i, "\n```\n")
      .gsub(/\[\/?highlight\]/i, "\n```\n")

    # [SAMP]...[/SAMP]
    raw = raw.gsub(/\[\/?samp\]/i, "`")

    # replace all chevrons with HTML entities
    # NOTE: must be done
    #  - AFTER all the "code" processing
    #  - BEFORE the "quote" processing
    raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub("<", "\u2603") + "`" }
      .gsub("<", "&lt;")
      .gsub("\u2603", "<")

    raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub(">", "\u2603") + "`" }
      .gsub(">", "&gt;")
      .gsub("\u2603", ">")

    # [URL=...]...[/URL]
    raw.gsub!(/\[url="?(.+?)"?\](.+?)\[\/url\]/i) { "<a href=\"#{$1}\">#{$2}</a>" }

    # [URL]...[/URL]
    # [MP3]...[/MP3]
    raw = raw.gsub(/\[\/?url\]/i, "")
      .gsub(/\[\/?mp3\]/i, "")

    # [MENTION]<username>[/MENTION]
    raw = raw.gsub(/\[mention\](.+?)\[\/mention\]/i) do
      old_username = $1
      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end
      "@#{old_username}"
    end

    # [USER=<user_id>]<username>[/USER]
    raw = raw.gsub(/\[user="?(\d+)"?\](.+?)\[\/user\]/i) do
      user_id, old_username = $1, $2
      if @old_username_to_new_usernames.has_key?(old_username)
        new_username = @old_username_to_new_usernames[old_username]
      else
        new_username = old_username
      end
      "@#{new_username}"
    end

    # [FONT=blah] and [COLOR=blah]
    # no idea why the /i is not matching case insensitive..
    raw.gsub! /\[color=.*?\](.*?)\[\/color\]/im, '\1'
    raw.gsub! /\[COLOR=.*?\](.*?)\[\/COLOR\]/im, '\1'
    raw.gsub! /\[font=.*?\](.*?)\[\/font\]/im, '\1'
    raw.gsub! /\[FONT=.*?\](.*?)\[\/FONT\]/im, '\1'

    # [CENTER]...[/CENTER]
    raw.gsub! /\[CENTER\](.*?)\[\/CENTER\]/im, '\1'

    # fix LIST
    raw.gsub! /\[LIST\](.*?)\[\/LIST\]/im, '<ul>\1</ul>'
    raw.gsub! /\[\*\]/im, '<li>'

    # [QUOTE]...[/QUOTE]
    raw = raw.gsub(/\[quote\](.+?)\[\/quote\]/im) { "\n> #{$1}\n" }

    # [QUOTE=<username>]...[/QUOTE]
    raw = raw.gsub(/\[quote=([^;\]]+)\](.+?)\[\/quote\]/im) do
      old_username, quote = $1, $2

      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end
      "\n[quote=\"#{old_username}\"]\n#{quote}\n[/quote]\n"
    end

    # [YOUTUBE]<id>[/YOUTUBE]
    raw = raw.gsub(/\[youtube\](.+?)\[\/youtube\]/i) { "\n//youtu.be/#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    raw = raw.gsub(/\[video=youtube;([^\]]+)\].*?\[\/video\]/i) { "\n//youtu.be/#{$1}\n" }

    raw
  end

  def postprocess_post_raw(raw)
    # [QUOTE=<username>;<post_id>]...[/QUOTE]
    raw = raw.gsub(/\[quote=([^;]+);n(\d+)\](.+?)\[\/quote\]/im) do
      old_username, post_id, quote = $1, $2, $3

      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end

      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        post_number = topic_lookup[:post_number]
        topic_id    = topic_lookup[:topic_id]
        "\n[quote=\"#{old_username},post:#{post_number},topic:#{topic_id}\"]\n#{quote}\n[/quote]\n"
      else
        "\n[quote=\"#{old_username}\"]\n#{quote}\n[/quote]\n"
      end
    end

    # remove attachments
    raw = raw.gsub(/\[attach[^\]]*\]\d+\[\/attach\]/i, "")

    # [THREAD]<thread_id>[/THREAD]
    # ==> http://my.discourse.org/t/slug/<topic_id>
    raw = raw.gsub(/\[thread\](\d+)\[\/thread\]/i) do
      thread_id = $1
      if topic_lookup = topic_lookup_from_imported_post_id("thread-#{thread_id}")
        topic_lookup[:url]
      else
        $&
      end
    end

    # [THREAD=<thread_id>]...[/THREAD]
    # ==> [...](http://my.discourse.org/t/slug/<topic_id>)
    raw = raw.gsub(/\[thread=(\d+)\](.+?)\[\/thread\]/i) do
      thread_id, link = $1, $2
      if topic_lookup = topic_lookup_from_imported_post_id("thread-#{thread_id}")
        url = topic_lookup[:url]
        "[#{link}](#{url})"
      else
        $&
      end
    end

    # [POST]<post_id>[/POST]
    # ==> http://my.discourse.org/t/slug/<topic_id>/<post_number>
    raw = raw.gsub(/\[post\](\d+)\[\/post\]/i) do
      post_id = $1
      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        topic_lookup[:url]
      else
        $&
      end
    end

    # [POST=<post_id>]...[/POST]
    # ==> [...](http://my.discourse.org/t/<topic_slug>/<topic_id>/<post_number>)
    raw = raw.gsub(/\[post=(\d+)\](.+?)\[\/post\]/i) do
      post_id, link = $1, $2
      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        url = topic_lookup[:url]
        "[#{link}](#{url})"
      else
        $&
      end
    end
    
    raw = raw.gsub(/\[attachment[^\]]*\]/i, "")
    raw = raw.gsub(/\[url[^\]]*\]/i, "")
    raw = raw.gsub(/\[hr[^\]]*\]/i, "")
    raw = raw.gsub(/\[size=.*?\](.*?)\[\/size\]/im, '\1')

    raw
  end

  def import_attachments
    puts '', 'importing attachments...'

    total_count = mysql_query(<<-SQL
      SELECT COUNT(pid)
        FROM #{TABLE_PREFIX}attachments
       WHERE pid <> 0
    SQL
    )

    posts = mysql_query(<<-SQL
      SELECT *
        FROM #{TABLE_PREFIX}attachments
       WHERE pid <> 0
    SQL
    )

    PostCustomField.where(name: 'import_id').pluck(:post_id, :value).each do |post_id, import_id|
      attachments = mysql_query(<<-SQL
        SELECT *
          FROM #{TABLE_PREFIX}attachments
        WHERE pid = #{import_id}
      SQL
      )

      next if attachments.size < 1

      attachments.each do |attachment|
        post = Post.find(post_id)

        upload, filename = find_upload(post, attachment)

        next unless upload

        html = html_for_upload(upload, filename)
        if !post.raw[html]
          post.raw << "\n\n" << html
          post.save!
          PostUpload.create!(post: post, upload: upload) unless PostUpload.where(post: post, upload: upload).exists?
        end
      end
    end
  end

  def find_upload(post, attachment)
    filename = File.join(ATTACHMENT_DIR, attachment['attachname'])
    real_filename = attachment['filename']
    real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

    return unless File.exists?(filename)

    upload = create_upload(post.user.id, filename, real_filename)

    if upload.nil? || !upload.valid?
      puts "Upload not valid :("
      puts upload.errors.inspect if upload
      return
    end

    [upload, real_filename]
  end

  def tag_name(tag)
    tag = DiscourseTagging.clean_tag(tag)
    
    unless tag[':'].nil?
      tag[':']= ''
    end

    tag
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::MyBB.new.perform
