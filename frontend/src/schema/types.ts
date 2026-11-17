/** The subset of JSON Schema that s2i_schema:json_schema/1 produces. */
export interface JsonSchema {
  type?: "object" | "array" | "string" | "integer" | "number" | "boolean";
  properties?: Record<string, JsonSchema>;
  required?: string[];
  /** Field order of the Erlang spec (JSON objects are unordered). */
  "x-order"?: string[];
  additionalProperties?: boolean | JsonSchema;
  propertyNames?: { pattern?: string };
  minProperties?: number;
  items?: JsonSchema;
  minItems?: number;
  uniqueItems?: boolean;
  oneOf?: JsonSchema[];
  discriminator?: { propertyName: string };
  enum?: (string | number)[];
  const?: string | number;
  default?: unknown;
  minimum?: number;
  maximum?: number;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  description?: string;
  writeOnly?: boolean;
  $ref?: string;
}

export type Path = (string | number)[];
