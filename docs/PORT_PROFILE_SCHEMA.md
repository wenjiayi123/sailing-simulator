# `ship_port_profile_v1` 港口场景配置

港口配置驱动 Godot 场景、障碍物和航行任务列表。可通过 `SHIP_PORT_PROFILE=/absolute/path/profile.json` 替换，或放到 Godot `user://port_profile.json` 中。

```json
{
  "schema_version": "ship_port_profile_v1",
  "name": "Port profile name",
  "source": {
    "type": "survey_or_project_native_geometry",
    "license": "SPDX-or-description",
    "observed_port_data": true
  },
  "scenario_order": ["harbor"],
  "navigation_missions": [
    {
      "name": "Inbound pilotage",
      "code": "PORT-INBOUND-01",
      "objective": "Pilotage objective",
      "scenario_key": "harbor",
      "loop": false,
      "arrival_radius": 12.0,
      "planned_speed_knots": 6.0,
      "spawn": {"x": 0.0, "z": 0.0, "heading_degrees": 90.0},
      "route": [{"x": 50.0, "z": 0.0}]
    }
  ],
  "scenarios": {
    "harbor": {
      "name": "Harbor",
      "description": "Source-aware description",
      "spawn": {"x": 0.0, "z": 0.0, "heading_degrees": 90.0},
      "boundary_half_extent": 500.0,
      "loop_route": false,
      "route": [{"x": 50.0, "z": 0.0}],
      "rocks": [{"x": 20.0, "z": 15.0}],
      "boxes": [
        {
          "name": "Pier",
          "position": {"x": 80.0, "z": 20.0},
          "size": {"x": 100.0, "y": 5.0, "z": 10.0}
        }
      ]
    }
  }
}
```

坐标为港口局部平面米制坐标：Godot `x` 对应东向，`z` 对应北向显示轴。转换 AIS 时使用的原点、投影、原始文件 SHA-256 与许可信息应保留在来源元数据中。
