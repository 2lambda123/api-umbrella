local error_handler = require "api-umbrella.proxy.error_handler"
local rewrite_response = require "api-umbrella.proxy.middleware.rewrite_response"

local ngx_ctx = ngx.ctx
local settings = ngx_ctx.settings

-- Perform any response rewriting.
local err = rewrite_response(ngx_ctx, settings)
if err then
  return error_handler(ngx_ctx, err, settings)
end
