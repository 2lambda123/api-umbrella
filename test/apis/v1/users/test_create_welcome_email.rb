require_relative "../../../test_helper"

class Test::Apis::V1::Users::TestCreateWelcomeEmail < Minitest::Test
  include ApiUmbrellaTestHelpers::AdminAuth
  include ApiUmbrellaTestHelpers::Setup
  include ApiUmbrellaTestHelpers::SentEmails

  def setup
    super
    setup_server

    response = Typhoeus.delete("http://127.0.0.1:#{$config["mailhog"]["api_port"]}/api/v1/messages")
    assert_response_code(200, response)
  end

  def test_sends_email_when_enabled
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(admin_token).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => { :send_welcome_email => true },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => true,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(1, sent_emails.length)
  end

  def test_no_email_when_disabled
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(admin_token).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => { :send_welcome_email => false },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => false,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(0, sent_emails.length)
  end

  def test_no_email_when_unknown_value
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(admin_token).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => { :send_welcome_email => 1 },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => false,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(0, sent_emails.length)
  end

  def test_no_email_by_default
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(admin_token).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(0, sent_emails.length)
  end

  def test_sends_email_when_user_attribute_has_any_value
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(admin_token).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user).merge({
          :send_welcome_email => "0",
        }),
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => true,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(1, sent_emails.length)
  end

  def test_non_admin
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(non_admin_key_creator_api_key).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => { :send_welcome_email => true },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => true,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    assert_equal(1, sent_emails.length)
  end

  def test_email_verification
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(non_admin_key_creator_api_key).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => {
          :send_welcome_email => true,
          :verify_email => true,
          :example_api_url => "https://localhost/api.json?api_key={{api_key}}&test=1",
        },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)

    assert_nil(data.fetch("user")["api_key"])
    user = ApiUser.find(data["user"]["id"])
    refute_match(user.api_key, response.body)

    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => true,
      "site_name" => "API Umbrella",
      "verify_email" => true,
    }, data.fetch("options"))

    messages = sent_emails
    assert_equal(1, messages.length)
    message = messages.first

    refute_nil(user.api_key)
    assert_match(%(<a href="https://localhost/api.json?api_key=#{user.api_key}&amp;test=1">https://localhost/api.json?<strong>api_key=#{user.api_key}</strong>&amp;test=1</a>), message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("\n\nhttps://localhost/api.json?api_key=#{user.api_key}&test=1\n\n\n", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))
  end

  def test_default_content
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(non_admin_key_creator_api_key).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user),
        :options => { :send_welcome_email => true },
      },
    }))
    assert_response_code(201, response)
    data = MultiJson.load(response.body)
    assert_equal({
      "contact_url" => "https://localhost/contact/",
      "send_welcome_email" => true,
      "site_name" => "API Umbrella",
    }, data.fetch("options"))

    messages = sent_emails
    assert_equal(1, messages.length)

    user = ApiUser.find(data["user"]["id"])
    message = messages.first

    # To
    refute_nil(user.email)
    assert_equal([user.email], message.fetch("Content").fetch("Headers").fetch("To"))

    # Greeting
    assert_match("Hi #{user.first_name},</p>", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Hi #{user.first_name},", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    assert_match("Your API key for <strong>#{user.email}</strong> is:</p>", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Your API key for #{user.email} is:", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    # API key
    refute_nil(user.api_key)
    assert_match(user.api_key, message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match(user.api_key, message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    # Subject
    assert_equal(["Your API Umbrella API key"], message.fetch("Content").fetch("Headers").fetch("Subject"))

    # From
    assert_equal(["noreply@localhost"], message.fetch("Content").fetch("Headers").fetch("From"))

    # Example API URL
    refute_match("Here's an example", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    refute_match("Here's an example", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    # Contact URL
    assert_match(%(<a href="https://localhost/contact/">contact us</a>), message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("contact us ( https://localhost/contact/ )", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    # Support footer
    assert_match("Account Email: #{user.email}", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Account Email: #{user.email}", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    assert_match("Account ID: #{user.id}", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Account ID: #{user.id}", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))
  end

  def test_customized_content
    prepend_api_backends([
      {
        :frontend_host => "example.com",
        :backend_host => "127.0.0.1",
        :servers => [{ :host => "127.0.0.1", :port => 9444 }],
        :url_matches => [{ :frontend_prefix => "/#{unique_test_id}/", :backend_prefix => "/" }],
      },
    ]) do
      response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(non_admin_key_creator_api_key).deep_merge({
        :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
        :body => {
          :user => FactoryBot.attributes_for(:api_user),
          :options => {
            :send_welcome_email => true,
            :site_name => "External Example",
            :email_from_name => "Tester",
            :email_from_address => "test@example.com",
            :example_api_url => "https://example.com/api.json?api_key={{api_key}}&test=1",
            :contact_url => "https://example.com/contact-us",
          },
        },
      }))
      assert_response_code(201, response)
      data = MultiJson.load(response.body)
      assert_equal({
        "contact_url" => "https://example.com/contact-us",
        "email_from_address" => "test@example.com",
        "email_from_name" => "Tester",
        "example_api_url" => "https://example.com/api.json?api_key=#{data.fetch("user").fetch("api_key")}&test=1",
        "example_api_url_formatted_html" => "https://example.com/api.json?<strong>api_key=#{data.fetch("user").fetch("api_key")}</strong>&amp;test=1",
        "send_welcome_email" => true,
        "site_name" => "External Example",
      }, data.fetch("options"))

      messages = sent_emails
      assert_equal(1, messages.length)

      user = ApiUser.find(data["user"]["id"])
      message = messages.first

      # To
      refute_nil(user.email)
      assert_equal([user.email], message.fetch("Content").fetch("Headers").fetch("To"))

      # API key
      refute_nil(user.api_key)
      assert_match(user.api_key, message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
      assert_match(user.api_key, message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

      # Subject
      assert_equal(["Your External Example API key"], message.fetch("Content").fetch("Headers").fetch("Subject"))

      # From
      assert_equal(["Tester <test@example.com>"], message.fetch("Content").fetch("Headers").fetch("From"))

      # URL Example
      assert_match("Here's an example", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
      assert_match("Here's an example", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))
      assert_match(%(<a href="https://example.com/api.json?api_key=#{user.api_key}&amp;test=1">https://example.com/api.json?<strong>api_key=#{user.api_key}</strong>&amp;test=1</a>), message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
      assert_match("\n\nhttps://example.com/api.json?api_key=#{user.api_key}&test=1\n\n\n", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

      # Contact URL
      assert_match(%(<a href="https://example.com/contact-us">contact us</a>), message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
      assert_match("contact us ( https://example.com/contact-us )", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))
    end
  end

  def test_html_escaping
    response = Typhoeus.post("https://127.0.0.1:9081/api-umbrella/v1/users.json", http_options.deep_merge(non_admin_key_creator_api_key).deep_merge({
      :headers => { "Content-Type" => "application/x-www-form-urlencoded" },
      :body => {
        :user => FactoryBot.attributes_for(:api_user, :email => "foo<script>&bar@example.com", :first_name => "Test&First", :last_name => "Test&Last"),
        :options => { :send_welcome_email => true },
      },
    }))
    assert_response_code(201, response)

    messages = sent_emails
    assert_equal(1, messages.length)

    data = MultiJson.load(response.body)
    user = ApiUser.find(data["user"]["id"])
    message = messages.first

    # Greeting
    assert_match("Hi Test&amp;First,</p>", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Hi Test&First,", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    assert_match("Your API key for <strong>foo&lt;script&gt;&amp;bar@example.com</strong> is:</p>", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Your API key for foo<script>&bar@example.com is:", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    # Support footer
    assert_match("Account Email: foo&lt;script&gt;&amp;bar@example.com", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Account Email: foo<script>&bar@example.com", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))

    assert_match("Account ID: #{user.id}", message.fetch("_mime_parts").fetch("text/html").fetch("_body"))
    assert_match("Account ID: #{user.id}", message.fetch("_mime_parts").fetch("text/plain").fetch("_body"))
  end

  private

  def non_admin_key_creator_api_key
    user = FactoryBot.create(:api_user, {
      :roles => ["api-umbrella-key-creator"],
    })

    { :headers => { "X-Api-Key" => user.api_key } }
  end
end
