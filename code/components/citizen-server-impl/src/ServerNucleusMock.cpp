#include <StdInc.h>

#include <CoreConsole.h>

#include <GameServer.h>
#include <HttpClient.h>

#include <ResourceEventComponent.h>
#include <ResourceManager.h>

#include <ServerInstanceBase.h>
#include <ServerLicensingComponent.h>

#include <StructuredTrace.h>

#include <TcpListenManager.h>
#include <NoticeLogicProcessor.h>

#include <chrono>

#define VMP_ALLOW_CFX_NUCLEUS 1

#if VMP_ALLOW_CFX_NUCLEUS

static InitFunction initFunction([]()
{
	static auto httpClient = new HttpClient();

	fx::ServerInstanceBase::OnServerCreate.Connect([](fx::ServerInstanceBase* instance)
	{
		using namespace std::chrono_literals;

		static bool registerSent = false;
		static bool registerSuccess = false;
		static std::chrono::milliseconds registerTimeout{};
		static auto registerDelay = 15s;

		instance->GetComponent<fx::GameServer>()->OnTick.Connect([instance]()
		{
			if (registerSuccess)
			{
				return;
			}

			if (registerSent && msec() < registerTimeout)
			{
				return;
			}

			// the GMP license session is created by ServerAuth.cpp (server/register.php)
			auto varManager = instance->GetComponent<console::Context>()->GetVariableManager();
			auto sessionVar = varManager->FindEntryRaw("sv_sessionId");
			auto secretVar = varManager->FindEntryRaw("sv_secret");

			if (!sessionVar || sessionVar->GetValue().empty() || sessionVar->GetValue() == "0" || !secretVar || secretVar->GetValue().empty())
			{
				return;
			}

			auto tlm = instance->GetComponent<fx::TcpListenManager>();

			auto reqJson = nlohmann::json::object({
				{ "session_id", sessionVar->GetValue() },
				{ "secret", secretVar->GetValue() },
				{ "port", fmt::sprintf("%d", tlm->GetPrimaryPort()) },
				{ "ipOverride", instance->GetComponent<fx::GameServer>()->GetIpOverrideVar()->GetValue() },
			});

			registerTimeout = msec() + registerDelay;
			registerSent = true;

			HttpRequestOptions opts;
			opts.ipv4 = true;

			httpClient->DoPostRequest(GMP_LICENSING_EP "api/register/?v=2", reqJson.dump(), opts, [instance](bool success, const char* data, size_t length)
			{
				auto backoff = [&]()
				{
					if (registerDelay < 15min)
					{
						registerDelay *= 2;
					}
					registerTimeout = msec() + registerDelay;
				};

				if (!success)
				{
					backoff();
					return;
				}

				std::string host;
				try
				{
					auto resp = nlohmann::json::parse(std::string(data, length));
					host = resp.value("host", "");
				}
				catch (const std::exception&)
				{
					backoff();
					return;
				}

				if (host.empty())
				{
					backoff();
					return;
				}

				auto url = fmt::sprintf("http://%s/", host);

				instance->GetComponent<fx::ResourceManager>()
					->GetComponent<fx::ResourceEventManagerComponent>()
					->QueueEvent2(
						"_cfx_internal:nucleusConnected",
						{},
						url
					);

				StructuredTrace({ "type", "nucleus_connected" }, { "url", url });

				static auto webVar = instance->AddVariable<std::string>("web_baseUrl", ConVar_None, host);

				registerSuccess = true;
			});
		});
	}, INT32_MAX);
});

#endif // VMP_ALLOW_CFX_NUCLEUS
