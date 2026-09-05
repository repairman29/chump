import { PublisherCoPilotConfig, defaultConfig } from "./config";

export function init(config: PublisherCoPilotConfig = defaultConfig): void {
  console.log("Publisher Co-Pilot initialized", config);
}
