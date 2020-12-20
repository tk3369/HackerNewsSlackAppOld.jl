module HackerNewsSlackApp

export handler, publish, monitor_hackernews

using HTTP
using Sockets
using JSON3
using Dates
using Memento

const ROUTER = HTTP.Router()
# const LOGGER = Memento.config!("debug"; fmt="[{level} | {name}]: {msg}")
info(logger, msg) = begin sleep(0.5); println(now(), " ", msg); end
error(logger, msg) = println(now(), " ", msg)
warn(logger, msg) = println(now(), " ", msg)
debug(logger, msg) = println(now(), " ", msg)
const LOGGER = nothing

# installed web hook
const WEB_HOOK_URL = ENV["HACKER_NEWS_SLACK_WEB_HOOK"]

# what to monitor
struct Monitor
    channel::Channel
    keywords::Any   # change to vector{string}?
    sent::Dict{String,DateTime}
end

# Slash command

function start_slash_command_server(port)
    HTTP.@register(ROUTER, "POST", "/", handler)    
    HTTP.serve(ROUTER, IPv4(0), port, verbose = true)
end

function handler(req::HTTP.Request)
    println(req)
    try
        headers = ["Content-type" => "application/json"]
        body = JSON3.write(msg)
        return HTTP.Response(200, headers, body = body)
    catch ex
        error(LOGGER, "exception ex=$ex")
        return HTTP.Response(500, "Sorry, got an exception.")
    end
end

# Web hook

function publish(msg::AbstractString, monitor::Monitor)
    if already_published(msg, monitor)
        debug(LOGGER, "Already published message: $msg")
    else
        info(LOGGER, "Publishing message: $msg")
        headers = ["Content-type" => "application/json"]
        data = JSON3.write(Dict("text" => msg))
        HTTP.post(WEB_HOOK_URL, headers, data)
        monitor.sent[msg] = now()  # remember that we have already sent
    end
    return nothing
end

already_published(msg::AbstractString, monitor::Monitor) = haskey(monitor.sent, msg)

# Monitoring 

function create_monitor(f::Function, keywords; interval = 60)
    info(LOGGER, "creating monitor")
    monitor = Monitor(Channel(32), keywords, Dict{String,DateTime}())
    task = @async monitor_loop(f, monitor, interval)
    return (monitor = monitor, task = task)
end

function monitor_loop(f::Function, monitor::Monitor, interval::Int)
    info(LOGGER, "started monitoring")
    while true
        f(monitor.keywords, monitor)  # execute client function
        if isready(monitor.channel)
            instruction = take!(monitor.channel)
            instruction == "stop" && break
        end
        info(LOGGER, "sleeping $interval seconds")
        sleep(interval)
    end
    info(LOGGER, "stopped monitoring")
end

function stop_monitor(monitor::Monitor)
    put!(monitor.channel, "stop")
    return nothing
end

# Hacker News API

# Container for a story. Underlying data is a Dict from parsing JSON.
struct Story
    by::String
    descendants::Union{Nothing,Int}
    score::Int
    time::Int
    id::Int
    title::String
    kids::Union{Nothing,Vector{Int}}
    url::Union{Nothing,String}
end

# Construct a Story from a Dict (or Dict-compatible) object
function Story(obj)
    value = (x) -> get(obj, x, nothing)
    return Story(
        obj[:by], 
        value(:descendants), 
        obj[:score], 
        obj[:time],
        obj[:id], 
        obj[:title], 
        value(:kids), 
        value(:url))
end

# Find top 500 stories from HackerNews.  Returns an array of story id's.
function fetch_top_stories()
    url = "https://hacker-news.firebaseio.com/v0/topstories.json"
    response = HTTP.request("GET", url)
    return JSON3.read(response.body)
end

# Get a specific story item
function fetch_story(id)
    url = "https://hacker-news.firebaseio.com/v0/item/$(id).json"
    response = HTTP.request("GET", url)
    return Story(JSON3.read(response.body))
end

# Get title for top N stories
top_stories(n::Int) = let stories = fetch_top_stories()
    fetch_story.(stories[1:min(n,end)])
end

# Top story titles
top_titles(n::Int) = getfield.(top_stories(n), :title)

# Interesting title?
is_interesting(title::AbstractString, keywords::AbstractVector{T}) where T <: AbstractString =
    match(Regex("\\b(" * join(keywords, "|") * ")\\b"), lowercase(title)) !== nothing

# Check if any of the top stories contains certain keywords
function monitor_hackernews(keywords::AbstractVector{T}; interval = 300) where T <: AbstractString
    return create_monitor(keywords; interval = interval) do kw, monitor
        info(LOGGER, "finding top 10")
        tt = top_titles(10)
        ii = is_interesting.(tt, Ref(kw))
        if any(ii)
            publish.(tt[ii], Ref(monitor))
        end
        info(LOGGER, "done")
    end
end

end # module

