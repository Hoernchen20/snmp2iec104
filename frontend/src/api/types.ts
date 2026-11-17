import type { components } from "./schema";

type S = components["schemas"];

export type Server = S["Server"];
export type Device = S["Device"];
export type Profile = S["Profile"];
export type Config = S["Config"];
export type Me = S["Me"];
export type User = S["User"];
export type UserInput = S["UserInput"];
export type Version = S["Version"];
export type AuditEntry = S["AuditEntry"];
export type Validation = S["Validation"];
export type DeviceStatus = S["DeviceStatus"];
export type ServerStatus = S["ServerStatus"];
export type GroupStatus = S["GroupStatus"];
export type Varbind = S["Varbind"];

export interface Status {
  devices: DeviceStatus[];
  servers: ServerStatus[];
  active_vsn: number | null;
  has_changes: boolean;
}

export type EntityKind = "servers" | "devices" | "profiles";

export interface EntityMap {
  servers: Server;
  devices: Device;
  profiles: Profile;
}

/** The schema name in the OpenAPI document for an entity kind. */
export const SCHEMA_OF: Record<EntityKind, "Server" | "Device" | "Profile"> = {
  servers: "Server",
  devices: "Device",
  profiles: "Profile",
};

export const LABEL: Record<EntityKind, { one: string; many: string }> = {
  servers: { one: "IEC server", many: "IEC servers" },
  devices: { one: "Device", many: "Devices" },
  profiles: { one: "Profile", many: "Profiles" },
};
