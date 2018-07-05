local Admin = require "api-umbrella.web-app.models.admin"
local config = require "api-umbrella.proxy.models.file_config"
local csrf = require "api-umbrella.web-app.utils.csrf"
local db = require "lapis.db"
local error_messages_by_field = require "api-umbrella.web-app.utils.error_messages_by_field"
local escape_html = require("lapis.html").escape
local flash = require "api-umbrella.web-app.utils.flash"
local hmac = require "api-umbrella.utils.hmac"
local http_headers = require "api-umbrella.utils.http_headers"
local is_empty = require("pl.types").is_empty
local lapis = require "lapis"
local lapis_config = require("lapis.config").get()
local pg_utils = require "api-umbrella.utils.pg_utils"
local resty_session = require "resty.session"
local session_cipher = require "api-umbrella.web-app.utils.session_cipher"
local session_identifier = require "api-umbrella.web-app.utils.session_identifier"
local session_postgresql_storage = require "api-umbrella.web-app.utils.session_postgresql_storage"
local t = require("api-umbrella.web-app.utils.gettext").gettext
local table_keys = require("pl.tablex").keys

local supported_languages = table_keys(LOCALE_DATA)

-- Custom error handler so we only show the default lapis debug details in
-- development, and a generic error page in production.
local function handle_error(self, err, trace)
  ngx.log(ngx.ERR, "Unexpected error: " .. (err or "") .. "\n" .. (trace or ""))

  if lapis_config.show_errors then
    return lapis.Application.handle_error(self, err, trace)
  else
    self.res.headers["Content-Type"] = "text/html"
    return {
      status = 500,
      render = require("api-umbrella.web-app.views.500"),
      layout = false,
    }
  end
end

-- Override the default render_error_request so that backtraces aren't output
-- as an HTTP header in the test enivironment. This lets us verify that no
-- backtraces are output, even in the test environment (so we can have tests
-- around what will happen with error handling in production).
local function render_error_request(self, r, err, trace)
  r:write(self.handle_error(r, err, trace))
  return self:render_request(r)
end

local function handle_404(self)
  self.res.headers["Content-Type"] = "text/html"
  return self:write({
    status = 404,
    render = require("api-umbrella.web-app.views.404"),
    layout = false,
  })
end

local function current_admin_from_token()
  local current_admin
  local auth_token = ngx.var.http_x_admin_auth_token
  if auth_token then
    local auth_token_hmac = hmac(auth_token)
    local admin = Admin:find({ authentication_token_hash = auth_token_hmac })
    if admin and not admin:is_access_locked() then
      current_admin = admin
    end
  end

  return current_admin
end

-- Use the "session_db" instance for storing session data after the admin has
-- logged in. This session is backed by the database, so we have better
-- server-side control on expiring sessions, and it can't be spoofed even with
-- knowledge of the encryption secret key.
local function init_session_db(self)
  if not self.session_db then
    self.session_db = resty_session.new({
      name = "_api_umbrella_session",
      secret = assert(config["secret_key"]),
      random = {
        length = 40,
      },
      cookie = {
        samesite = "Lax",
        secure = true,
        httponly = true,
        renew = 60 * 60, -- 1 hour
        lifetime = 12 * 60 * 60, -- 12 hours
      },
    })
    self.session_db.cipher = session_cipher.new(self.session_db)
    self.session_db.identifier = session_identifier
    self.session_db.storage = session_postgresql_storage.new(self.session_db)
  end
end

-- Use the "session_cookie" instance for storing session data prior to the
-- admin logging in (for things like CSRF tokens on the login form and flash
-- notices on the login page). While still secure (the data is encrypted in the
-- cookie), we have less control over expiring this data and it can be
-- manipulated by someone with knowledge of the encryption secret key. But we
-- use this prior to login to simplify maintenance of the database-backed store
-- (so random, unauthenticated visits to the login page by bots don't generate
-- session records in the database for the CSRF token).
local function init_session_cookie(self)
  if not self.session_cookie then
    self.session_cookie = resty_session.new({
      storage = "cookie",
      name = "_api_umbrella_session_client",
      secret = assert(config["secret_key"]),
      random = {
        length = 40,
      },
      cookie = {
        samesite = "Lax",
        secure = true,
        httponly = true,
        renew = 60 * 60, -- 1 hour
        lifetime = 12 * 60 * 60, -- 12 hours
      },
    })
    self.session_cookie.cipher = session_cipher.new(self.session_cookie)
    self.session_cookie.identifier = session_identifier
  end
end

local function current_admin_from_session(self)
  local current_admin
  self:init_session_db()
  self.session_db:open()
  if self.session_db and self.session_db.data and self.session_db.data["admin_id"] then
    local admin_id = self.session_db.data["admin_id"]
    local admin = Admin:find({ id = admin_id })
    if admin and not admin:is_access_locked() then
      current_admin = admin
    end
  end

  return current_admin
end

local function before_filter(self)
  -- For the test environment setup a middleware that looks for the
  -- "test_delay_server_responses" cookie on requests, and if it's set, sleeps
  -- for that amount of time before returning responses.
  --
  -- This can be used for some Capybara integration tests that otherwise might
  -- happen too quickly (for example, checking that a loading spinner pops up
  -- while making an ajax request).
  if config["app_env"] == "test" then
    if ngx.var.cookie_test_delay_server_responses then
      ngx.sleep(tonumber(ngx.var.cookie_test_delay_server_responses))
    end
  end

  self.res.headers["Cache-Control"] = "no-cache, max-age=0, must-revalidate, no-store"
  self.res.headers["Pragma"] = "no-cache"

  -- Set session variables for the database connection (always use UTC and set
  -- an app name for auditing).
  --
  -- Ideally we would only set these once per connection (and not set it when
  -- the socket is reused), but Lapi's "db" instance doesn't have a way to get
  -- the underlying pgmoon connection before executing a query (the connection
  -- is lazily established after the first query).
  db.query("SET SESSION application_name = 'api-umbrella-web-app'")
  db.query("SET SESSION timezone = 'UTC'")

  -- Note that ngx.ctx.pgmoon will only be set after running the db.query
  -- above. If this issue gets addressed there might be a better way to access
  -- the underlying pgmoon object from Lapis:
  -- https://github.com/leafo/lapis/issues/565
  pg_utils.setup_type_casting(ngx.ctx.pgmoon)

  ngx.ctx.locale = http_headers.preferred_accept_language(ngx.var.http_accept_language, supported_languages)
  self.t = function(_, message)
    return t(message)
  end

  self.field_errors = function(_, field)
    if not self.error_messages_by_field then
      self.error_messages_by_field = error_messages_by_field(self.errors)
    end

    if self.error_messages_by_field and not is_empty(self.error_messages_by_field[field]) then
      table.sort(self.error_messages_by_field[field])
      return '<span class="help-block">' .. escape_html(table.concat(self.error_messages_by_field[field], ", ")) .. "</span>"
    else
      return ""
    end
  end

  self.field_errors_class = function(_, field)
    if not self.error_messages_by_field then
      self.error_messages_by_field = error_messages_by_field(self.errors)
    end

    if self.error_messages_by_field and not is_empty(self.error_messages_by_field[field]) then
      return " has-error"
    else
      return ""
    end
  end

  self.generate_csrf_token = function()
    return csrf.generate_token(self)
  end

  self.init_session_db = init_session_db
  self.init_session_cookie = init_session_cookie
  local current_admin = current_admin_from_token()
  if not current_admin then
    current_admin = current_admin_from_session(self)
  end
  self.current_admin = current_admin
  ngx.ctx.current_admin = current_admin

  flash.setup(self)
end

local app = lapis.Application()
app:enable("etlua")
app.layout = require "api-umbrella.web-app.views.layout"
app.handle_error = handle_error
app.render_error_request = render_error_request
app.handle_404 = handle_404
app:before_filter(before_filter)

require("api-umbrella.web-app.actions.admin.auth_external")(app)
require("api-umbrella.web-app.actions.admin.passwords")(app)
require("api-umbrella.web-app.actions.admin.registrations")(app)
require("api-umbrella.web-app.actions.admin.server_side_loader")(app)
require("api-umbrella.web-app.actions.admin.sessions")(app)
require("api-umbrella.web-app.actions.admin.stats")(app)
require("api-umbrella.web-app.actions.admin.unlocks")(app)
require("api-umbrella.web-app.actions.v0.analytics")(app)
require("api-umbrella.web-app.actions.v1.admin_groups")(app)
require("api-umbrella.web-app.actions.v1.admin_permissions")(app)
require("api-umbrella.web-app.actions.v1.admins")(app)
require("api-umbrella.web-app.actions.v1.analytics")(app)
require("api-umbrella.web-app.actions.v1.api_scopes")(app)
require("api-umbrella.web-app.actions.v1.apis")(app)
require("api-umbrella.web-app.actions.v1.config")(app)
require("api-umbrella.web-app.actions.v1.contact")(app)
require("api-umbrella.web-app.actions.v1.user_roles")(app)
require("api-umbrella.web-app.actions.v1.users")(app)
require("api-umbrella.web-app.actions.v1.website_backends")(app)

if config["app_env"] == "test" then
  app:get("/api-umbrella/v1/test-500", function()
    error("Testing unexpected raised error")
  end)
end

return app
