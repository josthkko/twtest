require 'twitter'
require 'redis'
require_relative 'conf'

STDOUT.sync = true

def twitter_client
  Twitter::REST::Client.new do |config|
	  config.consumer_key        = $cons_key
	  config.consumer_secret     = $cons_sec
	  config.access_token        = $acc_tok
	  config.access_token_secret = $acc_tok_sec
  end
end

def redis_client
	Redis.new
end

def fetch_all_followers(twitter_username = "", max_attempts = 100)
	# in theory, one failed attempt will occur every 15 minutes, so this could be long-running
	# with a long list of friends

	num_attempts = 0
	client = twitter_client
	redis = redis_client
	running_count = 0
	#reset my followers db, so we get only people who are actually following us
	redis.del("my_followers")

	if(twitter_username != "")	
		redis.sadd("tw_targets", twitter_username)
	end
	begin
		num_attempts += 1
		# 5000 is max for one request
		#followers = client.follower_ids(twitter_username).to_a
		followers = client.follower_ids(twitter_username).each_slice(5000).map do |slice|
			puts "Waiting for another slice..."
			sleep 61
			slice
		end.flatten

		if(twitter_username != "")	
			redis.sadd(twitter_username, followers)
		else
			redis.sadd("my_followers", followers)
		end
		followers.each do |f|
			running_count += 1
		end
	  	puts "Found #{running_count}"
	rescue Twitter::Error::TooManyRequests => error
		if num_attempts <= max_attempts
			puts "#{running_count} done from rescue block..."
			puts "Hit rate limit, sleeping for #{error.rate_limit.reset_in}..."
			sleep error.rate_limit.reset_in
			retry
		else
			raise
		end
	end
	if(twitter_username != "")	
		puts "In db #{redis.smembers(twitter_username).size}"
	else
		puts "My followers in db #{redis.smembers("my_followers").size}"
	end
end

#who are we following?
def fetch_my_friends(max_attempts = 100)
	# in theory, one failed attempt will occur every 15 minutes, so this could be long-running
	# with a long list of friends
	num_attempts = 0
	client = twitter_client
	redis = redis_client
	running_count = 0
	#clear previous friends, only use actual current friends
	redis.del("my_friends")
	begin
		num_attempts += 1
		# 5000 is max for one request
		friends = client.friend_ids.each_slice(5000).map do |slice|
			puts "Waiting for another slice..."
			sleep 61
			slice
		end.flatten

		redis.sadd("my_friends", friends)
		friends.each do |f|
			running_count += 1
		end
	  	puts "Found #{running_count} friends"
	rescue Twitter::Error::TooManyRequests => error
		if num_attempts <= max_attempts
			puts "#{running_count} done from rescue block..."
			puts "Hit rate limit, sleeping for #{error.rate_limit.reset_in}..."
			sleep error.rate_limit.reset_in
			retry
		else
			raise
		end
	end
	
	puts "My friends in db #{redis.smembers("my_friends").size}"
end

#init
if ARGV[0] == ""
	twName = "WorldAthleticsC" #1560 followers
else
	twName = ARGV[0]
end
#twName = "kurtbusch3" 55K followers
#twName = "BrianLVickers" #132K followers
#fetch_all_followers(twName)

followed_today = 0
unfollowed_today = 0
favorited_today = 0
start_time = Time.now.to_i
while true do

	fetch_all_followers()
	fetch_my_friends()
	#exit

	redis = redis_client
	twClient = twitter_client
	#redis.del("followed_archive")
	#puts "deleted!!"
	#redis.sadd("followed_archive", "0000000")
	#exit
	#redis.del("followed_archive")
	#exit
	#puts redis.zrange("followed", 0, -1, :with_scores => true)
	#exit
	#puts redis.zrangebyscore("followed", 0, Time.now.to_i - (3*24*60*60), :with_scores => true)
	#exit

	#remove users that are already following us
	intersect_arr = redis.sinter(twName, "my_followers")
	if !intersect_arr.empty?
		redis.srem(twName, intersect_arr)
	end
	#remove users that we are already following
	intersect_arr = redis.sinter(twName, "my_friends")
	if !intersect_arr.empty?
		redis.srem(twName, intersect_arr)
	end
	#remove users that we have already followed at some point
	intersect_arr = redis.sinter(twName, "followed_archive")
	if !intersect_arr.empty?
		redis.srem(twName, intersect_arr)
	end

	#puts "List of target users"
	#puts redis.smembers("tw_targets")
	followed_today = redis.zrangebyscore("followed", Time.now.to_i - (24*60*60), Time.now.to_i).count
	puts "followed today: #{followed_today}"
	num_added = 0
	if followed_today < 80
		#follow all users
		redis.smembers(twName).each do |twUser, i|
			#check if his last tweet was recent (less than 5 dayz)
			begin
				puts "checking profile: #{twUser}"
				sleep 6
				#last_tweet = twClient.user_timeline(twUser.to_i,{:count => 1}).to_a
				#posted_at = last_tweet[0].created_at.to_date
				#diff = (Date.today - posted_at).to_i
				#calculate diff between followers and following, we need users that are following more than they have followers
				user = twClient.user(twUser.to_i)
				users_friends = user.friends_count
				diff = users_friends / (user.followers_count + 1)
				if diff > 1 && users_friends > 50 && diff < 20
					twClient.follow!(twUser.to_i)
					puts "followed #{twUser}, his ratio is #{diff}"
					redis.srem(twName, twUser)
					redis.zadd("followed", Time.now.to_i, twUser)
					#add to archive of all follows, so we don't follow and unfollow a user twice
					redis.sadd("followed_archive", twUser)
					num_added += 1
					sleep 80 + Random.new.rand(10..30)
				else
					redis.srem(twName, twUser)
					redis.sadd(twName + "_inactive", twUser)
					puts "moved #{twUser} to #{twName}_inactive list, his ratio is #{diff}"
				end
			rescue Twitter::Error::Unauthorized => error
				puts error
				redis.srem(twName, twUser)
				redis.sadd(twName + "_inactive", twUser)
				puts "moved #{twUser} to #{twName}_inactive list"
			rescue Twitter::Error::TooManyRequests => error
				puts error
				sleep error.rate_limit.reset_in
			rescue Twitter::Error => error
				puts error
				redis.srem(twName, twUser)
				redis.sadd(twName + "_inactive", twUser)
				puts "moved #{twUser} to #{twName}_inactive list"
			rescue NoMethodError => error
				puts error
				redis.srem(twName, twUser)
				redis.sadd(twName + "_inactive", twUser)
				puts "moved #{twUser} to #{twName}_inactive list"
			end

			#TODO add according to number of followers/following
			break if num_added > 10
		end
		followed_today += num_added
		num_added = 0
	else
		puts "Follow limit reached"
	end

	#check for followers again
	fetch_all_followers()

	num_unfollowed = 0
	num_old_follows = redis.zrangebyscore("followed", 0, Time.now.to_i - (10*24*60*60)).count
	puts "#{num_old_follows} follows more than 10 days old found"
	unfollowed_today = redis.zrangebyscore("unfollowed", Time.now.to_i - (24*60*60), Time.now.to_i).count
	puts "Unfollowed today: #{unfollowed_today}"
	#the unfollowing part
	if unfollowed_today < 120
		#get people we are actually following
		redis.smembers("my_friends").each do |twUser|
			if redis.zrank("followed", twUser).nil?
				redis.zadd("followed", Time.now.to_i, twUser)
			end
		end
		#the people we are actually following right now get stored in followed_actual temporarily
		redis.zinterstore("followed_actual",["followed","my_friends"], :aggregate => "max")

		#check when have they been added, if older unfollow, but take care if he is following us
		#start unfollowing after a few days
		redis.zrangebyscore("followed_actual", 0, Time.now.to_i - (5*24*60*60)).each do |twUser|
			
			if !redis.sismember("my_followers", twUser)
				begin
					twClient.unfollow(twUser.to_i)
					puts "unfollowed #{twUser}"
					num_unfollowed += 1
					redis.zrem("followed", twUser)
					redis.zadd("unfollowed", Time.now.to_i, twUser)
					sleep 80 + Random.new.rand(10..30)
				rescue Twitter::Error::NotFound => error
					puts error
					redis.zrem("followed", twUser)
					redis.zadd("unfollowed", Time.now.to_i, twUser)
				end
			else
				puts "#{twUser} is my follower and I won't unfollow him"
			end

			#TODO unfollow only some percentage of folks
			break if num_unfollowed > 3
		end	
		#delete actual following, it will be recreated in next iteration
		redis.del("followed_actual")
	else
		puts "Unfollow limit reached"
	end
	unfollowed_today += num_unfollowed
	num_unfollowed = 0

	#favourite some tweets
	favorited_today = redis.zrangebyscore("favourited", Time.now.to_i - (24*60*60), Time.now.to_i).count
	if favorited_today < 80 
		twClient.search("#gaming -$ -%", :result_type => "recent").take(30).each do |tweet|
			puts "found tweet: #{tweet.text}"
			if tweet.source == "web"
				if redis.zrank("favourited", tweet.id).nil?
					twClient.favorite(tweet.id)
					redis.zadd("favourited", Time.now.to_i, tweet.id)
					puts "favorited!"
					sleep Random.new.rand(40..60)
				else
					puts "Already favourited!"
				end
			else
				puts "Tweet by a bot!"
			end
			sleep Random.new.rand(1..4)
		end
		sleep Random.new.rand(5..10)
		#just duplicate from above -> put in function
		twClient.search("soccer OR football", :result_type => "recent").take(30).each do |tweet|
			puts "found tweet: #{tweet.text}"
			if tweet.source == "web"
				if redis.zrank("favourited", tweet.id).nil?
					twClient.favorite(tweet.id)
					redis.zadd("favourited", Time.now.to_i, tweet.id)
					puts "favorited!"
					sleep Random.new.rand(40..60)
				else
					puts "Already favourited!"
				end
			else
				puts "Tweet by a bot!"
			end
			sleep Random.new.rand(1..4)
		end
		sleep Random.new.rand(5..10)
	else
		puts "favourite limit reached for 24h!"
	end
	puts "---------------------------------------------------------------"
	puts "total followed today #{followed_today}"
	puts "total unfollowed today #{unfollowed_today}"
	puts "total favorited today #{favorited_today}"
	puts "---------------------------------------------------------------"
	puts "Sleeping now.... Time is: #{Time.now.utc.to_s}"
	sleep Random.new.rand(900..1800) #3600 + Random.new.rand(300..1800)

	if Time.now.to_i - 24*60*60 > start_time
		followed_today = 0
		unfollowed_today = 0
		start_time = Time.now.to_i
	end
end
