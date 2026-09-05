export interface PublisherCoPilotConfig {
  platformCredentials: {
    apiKey: string;
    apiSecret: string;
    accountId: string;
  };
}

export const defaultConfig: PublisherCoPilotConfig = {
  platformCredentials: {
    apiKey: "",
    apiSecret: "",
    accountId: "",
  },
};
