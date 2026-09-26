export interface PlatformCredentials {
  apiKey: string;
  apiSecret: string;
  accessToken: string;
}

export interface PublisherCoPilotConfig {
  platform: string;
  credentials: PlatformCredentials;
}

export const defaultConfig: PublisherCoPilotConfig = {
  platform: "",
  credentials: {
    apiKey: "",
    apiSecret: "",
    accessToken: "",
  },
};
