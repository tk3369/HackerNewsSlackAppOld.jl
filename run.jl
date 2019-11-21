using HackerNewsSlackApp

monitor, task = monitor_hackernews([
           "julia", "python", "typescript", "javascript", "hong kong", 
           "google", "facebook", "paypal"
       ], interval = 300)

wait(task)
