# aws-sdk-core (spinel-aws-sdk-core)

The [aws-sdk-core](https://rubygems.org/gems/aws-sdk-core) gem for Spinel,
with the AWS Security Token Service client it ships (`Aws::STS::Client`).
`require "aws-sdk-core"` and the names are the gem's, and every test's
expected output is the real gem's. It depends on
[spinel-aws-sigv4](https://github.com/aristotelesbr/spinel-aws-sigv4), as
the gem depends on aws-sigv4.

```ruby
require "aws-sdk-core"

sts = Aws::STS::Client.new(region: "us-east-1")
sts.get_caller_identity.account
# => "123456789012"

role = Aws::AssumeRoleCredentials.new(
  role_arn: "arn:aws:iam::123456789012:role/app", role_session_name: "app"
)
role.credentials.access_key_id
# => "ASIA..."

stubbed = Aws::STS::Client.new(stub_responses: true)
stubbed.stub_responses(:get_caller_identity, { account: "111" })
stubbed.get_caller_identity.account
# => "111"
```

## How it is built

The package has three parts:

- **The gem's credentials, as source.** `aws-sdk-core/` holds the gem's
  credential files from aws-sdk-core 3.257.0: credentials and their
  providers, the provider chain, the shared config and credentials files,
  assume role, web identity, ARNs and errors. `git diff bc827be` (the
  commit that adds them verbatim) shows every change. `waiters/errors.rb`
  is the gem's too, unchanged. Each change is marked
  `# spinel-aws-sdk-core:` in place.
- **A generated client.** The gem builds its clients at run time from each
  service's API model. Here `aws-sdk-sts.rb` and `aws-sdk-sts/` are
  generated ahead of time from the same model (`apis/sts/2011-06-15` in
  aws-sdk-ruby), as plain Ruby: types, errors, serializers, parsers, stubs
  and the client. `UPSTREAM` names the model and generator versions.
- **A small runtime.** `aws-sdk-core/runtime.rb` and
  `aws-sdk-core/runtime/` (retries, JSON, the waiter loop) are written for
  the package. They do what the gem's request handlers do for a
  query-protocol service (STS) and a JSON-protocol service (such as
  [SSM](https://github.com/aristotelesbr/spinel-aws-sdk-ssm)): resolve the
  region, credentials and endpoint, sign with SigV4, send over `Net::HTTP`,
  read the XML or JSON, raise the service's errors, retry, and stub.

## What was rewritten, and why

| Where | The gem | Here | Why |
|---|---|---|---|
| `aws-sdk-core.rb` | autoloads every part, Seahorse, aws-partitions and jmespath | requires the parts the package carries | the package carries what the client needs |
| `errors.rb`, `ServiceError#initialize` | `DynamicErrors` creates a class per error code at run time and sets its code | error classes are generated; the code is passed in, and defaults to nil | a compiled program defines its classes ahead of time |
| `errors.rb`, `possible_regions` | lists the regions from aws-partitions | empty | the package does not carry aws-partitions |
| `refreshing_credentials.rb` | `self.class::SYNC_EXPIRATION_LENGTH` and `ASYNC_` | the module's constants | the gem's form does not run under Spinel yet |
| `shared_config.rb` | `config_reader` defines 33 readers | the 33 readers written out | a compiled program defines its methods ahead of time |
| `shared_config.rb`, `credential_provider_chain.rb` | `with_metrics` records User-Agent metrics | runs its block | the package does not build the User-Agent metrics |
| `assume_role*_credentials.rb` | reads the operation's members from the API model | `STS::Client.input_members` | the model is not loaded at run time |

The runtime follows the gem's behaviour for:

- region and credentials, in the gem's order;
- endpoints per partition;
- configured endpoints (`AWS_ENDPOINT_URL*`, `endpoint_url` and `services`);
- unsigned operations;
- `stub_responses`;
- paging (`each_page`, `next_page`, `last_page?`) for a paginator of one token;
- waiters (`Aws::Waiters::Waiter` and its errors), for a generated waiter class;
- error classes, including common AWS errors the model does not list;
- the `legacy` (default) and `standard` retry modes, with the retry quota and clock skew correction.

## Known gaps

- The package's own client is STS. Other services are their own packages,
  each with a generated client.
- The credential chain carries static, environment, shared files, assume
  role and web identity credentials. With none of these set, set
  `AWS_EC2_METADATA_DISABLED=true` so the chain ends without looking for
  the instance-profile provider.
- Credentials come from `AWS_PROFILE`, not from a `profile:` client option.
- FIPS and dual-stack endpoints, the `adaptive` retry mode and SigV4a are
  not included.

## Tests

```sh
LIBRARY_PATH=$(brew --prefix openssl@3)/lib spin test   # each test compiled by Spinel against its .expected
sh oracle/run.sh                                        # the real gem and this package under CRuby 4.0.2
sh oracle/run.sh --write                                # regenerate .expected from the real gem
```

`LIBRARY_PATH` lets the link find Homebrew's OpenSSL (matz/spinel#7191).
The oracle needs [mise](https://mise.jdx.dev) with Ruby 4.0.2 and the gem
installed once: `cd oracle && BUNDLE_GEMFILE=$PWD/Gemfile mise exec ruby@4.0.2 -- bundle install`.
It takes this package's include paths from `spin flags`; set `SPIN` to the
spin binary if the one on `PATH` is not current.

The tests cover:

- `credentials_test.rb`: the provider chain and the shared files;
- `stubs_test.rb`: `stub_responses`;
- `network_test.rb`: requests, signatures, errors and endpoints against a local server;
- `retry_test.rb`: retries;
- `assume_role_test.rb`: assume role and web identity;
- `endpoints_test.rb`: configured endpoints.

Every `.expected` is the real gem's output. Tested with Spinel `9a121acc5`.

## License

Apache-2.0, as the gem. See `LICENSE` and `NOTICE`.
