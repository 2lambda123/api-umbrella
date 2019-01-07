FactoryBot.define do
  factory :rate_limit do
    duration { 60000 }
    accuracy { 5000 }
    distributed { true }
    limit_by { "ip" }
    limit { 500 }
    response_headers { false }
  end
end
