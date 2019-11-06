local ApiUser = require "api-umbrella.web-app.models.api_user"
local api_user_admin_notification_mailer = require "api-umbrella.web-app.mailers.api_user_admin_notification"
local api_user_policy = require "api-umbrella.web-app.policies.api_user_policy"
local api_user_welcome_mailer = require "api-umbrella.web-app.mailers.api_user_welcome"
local capture_errors_json_full = require("api-umbrella.web-app.utils.capture_errors").json_full
local config = require "api-umbrella.proxy.models.file_config"
local datatables = require "api-umbrella.web-app.utils.datatables"
local db = require "lapis.db"
local dbify_json_nulls = require "api-umbrella.web-app.utils.dbify_json_nulls"
local deep_merge_overwrite_arrays = require "api-umbrella.utils.deep_merge_overwrite_arrays"
local deepcopy = require("pl.tablex").deepcopy
local escape_html = require("lapis.html").escape
local flatten_headers = require "api-umbrella.utils.flatten_headers"
local is_array = require "api-umbrella.utils.is_array"
local is_empty = require("pl.types").is_empty
local is_hash = require "api-umbrella.utils.is_hash"
local json_response = require "api-umbrella.web-app.utils.json_response"
local known_domains = require "api-umbrella.utils.known_domains"
local parse_post_for_pseudo_ie_cors = require "api-umbrella.web-app.utils.parse_post_for_pseudo_ie_cors"
local require_admin = require "api-umbrella.web-app.utils.require_admin"
local respond_to = require "api-umbrella.web-app.utils.respond_to"
local validation_ext = require "api-umbrella.web-app.utils.validation_ext"
local wrapped_json_params = require "api-umbrella.web-app.utils.wrapped_json_params"

local db_null = db.NULL
local gsub = ngx.re.gsub

local _M = {}

local function get_options(self)
  local options = deepcopy(self.params["options"]) or {}
  options["example_api_url"] = known_domains.sanitized_api_url(options["example_api_url"])
  options["contact_url"] = known_domains.sanitized_url(options["contact_url"])
  options["email_from_address"] = known_domains.sanitized_email(options["email_from_address"])

  if options["send_notify_email"] ~= nil then
    options["send_notify_email"] = (tostring(options["send_notify_email"]) == "true")
  end

  if options["send_welcome_email"] ~= nil then
    options["send_welcome_email"] = (tostring(options["send_welcome_email"]) == "true")
  end

  -- For the admin tool, it's easier to have this attribute on the user model,
  -- rather than options, so check there for whether we should send e-mail.
  -- Also note that for backwards compatibility, we only check for the presence
  -- of this attribute, and not it's actual value.
  if not options["send_welcome_email"] and self.params and type(self.params["user"]) == "table" and self.params["user"]["send_welcome_email"] then
    options["send_welcome_email"] = true
  end

  if options["verify_email"] ~= nil then
    options["verify_email"] = (tostring(options["verify_email"]) == "true")
  end

  if is_empty(options["contact_url"]) then
    options["contact_url"] = "https://" .. config["web"]["default_host"] .. "/contact/"
  end

  if is_empty(options["site_name"]) then
    options["site_name"] = config["site_name"]
  end

  return options
end

local function options_output(options, response)
  if not is_empty(options["example_api_url"]) then
    options["example_api_url_formatted_html"] = gsub(escape_html(options["example_api_url"]), "api_key={{api_key}}", "<strong>api_key=" .. response["user"]["api_key"] .. "</strong>", "jo")
    options["example_api_url"] = gsub(options["example_api_url"], "{{api_key}}", response["user"]["api_key"], "jo")
  end

  return options
end

local function send_admin_notification_email(api_user, options)
  local send_email = false
  if options["send_notify_email"] then
    send_email = true
  end

  if not send_email and tostring(config["web"]["send_notify_email"]) == "true" then
    send_email = true
  end

  if not send_email then
    return nil
  end

  local ok, err = api_user_admin_notification_mailer(api_user, options)
  if not ok then
    ngx.log(ngx.ERR, "mail error: ", err)
  end
end

local function send_welcome_email(api_user, options)
  if not options["send_welcome_email"] then
    return nil
  end

  local ok, err = api_user_welcome_mailer(api_user, options)
  if not ok then
    ngx.log(ngx.ERR, "mail error: ", err)
  end
end

function _M.index(self)
  return datatables.index(self, ApiUser, {
    where = {
      api_user_policy.authorized_query_scope(self.current_admin),
    },
    search_joins = {
      "LEFT JOIN api_users_roles ON api_users.id = api_users_roles.api_user_id",
    },
    search_fields = {
      "first_name",
      "last_name",
      "email",
      { name = "api_key_prefix", prefix_length = ApiUser.API_KEY_PREFIX_LENGTH },
      "registration_source",
      db.raw("api_users_roles.api_role_id"),
    },
    order_fields = {
      "email",
      "first_name",
      "last_name",
      "use_description",
      "registration_source",
      "created_at",
      "updated_at",
    },
    preload = {
      "roles",
      settings = {
        "rate_limits",
      },
    },
    csv_filename = "users",
  })
end

function _M.show(self)
  self.api_user:authorize()
  local response = {
    user = self.api_user:as_json({ allow_api_key = true }),
  }

  return json_response(self, response)
end

function _M.create(self)
  local options = get_options(self)

  -- Wildcard CORS header to allow the signup form to be embedded anywhere.
  self.res.headers["Access-Control-Allow-Origin"] = "*"

  local request_headers = flatten_headers(ngx.req.get_headers())

  local user_params = _M.api_user_params(self)
  user_params["registration_ip"] = ngx.var.remote_addr
  user_params["registration_user_agent"] = request_headers["user-agent"]
  user_params["registration_referer"] = request_headers["referer"]
  user_params["registration_origin"] = request_headers["origin"]
  if self.params and type(self.params["user"]) == "table" and type(self.params["user"]["registration_source"]) == "string" and self.params["user"]["registration_source"] ~= "" then
    user_params["registration_source"] = self.params["user"]["registration_source"]
  else
    user_params["registration_source"] = "api"
  end

  -- If email verification is enabled, then create the record and mark its
  -- email_verified field as true. Since the API key won't be part of the API
  -- response and will only be included in the e-mail to the user, we can
  -- assume that if the key is being used the it's only because it was received
  -- at the user's e-mail address.
  if options["verify_email"] or self.current_admin then
    user_params["email_verified"] = true
  else
    user_params["email_verified"] = false
  end

  local api_user = assert(ApiUser:authorized_create(user_params))
  local response = {
    user = api_user:as_json({ allow_api_key = true }),
  }
  response["options"] = options_output(options, response)

  -- On api key signup by public users, return the API key as part of the
  -- immediate response unless email verification is enabled.
  if not self.current_admin and not options["verify_email"] then
    response["user"]["api_key"] = api_user:api_key_decrypted()
  end

  send_admin_notification_email(api_user, options)
  send_welcome_email(api_user, options)

  self.res.status = 201
  return json_response(self, response)
end

function _M.update(self)
  local options = get_options(self)

  self.api_user:authorized_update(_M.api_user_params(self))
  local response = {
    user = self.api_user:as_json(),
  }
  response["options"] = options_output(options, response)

  self.res.status = 200
  return json_response(self, response)
end

local function api_user_settings_params(input_settings)
  if not input_settings then
    return nil
  end

  if not is_hash(input_settings) then
    return db_null
  end

  local params_settings = dbify_json_nulls({
    id = input_settings["id"],
    allowed_ips = input_settings["allowed_ips"],
    allowed_referers = input_settings["allowed_referers"],
    rate_limit_mode = input_settings["rate_limit_mode"],
  })

  if input_settings["rate_limits"] then
    params_settings["rate_limits"] = {}
    if is_array(input_settings["rate_limits"]) then
      for _, input_rate_limit in ipairs(input_settings["rate_limits"]) do
        table.insert(params_settings["rate_limits"], dbify_json_nulls({
          id = input_rate_limit["id"],
          duration = input_rate_limit["duration"],
          limit_by = input_rate_limit["limit_by"],
          limit_to = input_rate_limit["limit"],
          response_headers = input_rate_limit["response_headers"],
        }))
      end
    end
  end

  return params_settings
end

function _M.api_user_params(self)
  local params = {}
  if self.params and type(self.params["user"]) == "table" then
    local input = self.params["user"]
    params = dbify_json_nulls({
      email = input["email"],
      first_name = input["first_name"],
      last_name = input["last_name"],
      use_description = input["use_description"],
      website = input["website"],
      terms_and_conditions = input["terms_and_conditions"],
    })

    if self.current_admin then
      deep_merge_overwrite_arrays(params, dbify_json_nulls({
        throttle_by_ip = input["throttle_by_ip"],
        enabled = input["enabled"],
        role_ids = input["roles"],
      }))

      if input["settings"] then
        params["settings"] = api_user_settings_params(input["settings"])
      end
    end
  end

  return params
end

return function(app)
  app:match("/api-umbrella/v1/users/:id(.:format)", respond_to({
    before = require_admin(function(self)
      local ok = validation_ext.string.uuid(self.params["id"])
      if ok then
        self.api_user = ApiUser:find(self.params["id"])
      end
      if not self.api_user then
        return self.app.handle_404(self)
      end
    end),
    GET = capture_errors_json_full(_M.show),
    POST = capture_errors_json_full(wrapped_json_params(_M.update, "user")),
    PUT = capture_errors_json_full(wrapped_json_params(_M.update, "user")),
  }))

  app:match("/api-umbrella/v1/users(.:format)", respond_to({
    GET = require_admin(capture_errors_json_full(_M.index)),
    POST = capture_errors_json_full(parse_post_for_pseudo_ie_cors(wrapped_json_params(_M.create, "user"))),
  }))
end
