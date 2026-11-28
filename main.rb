# frozen_string_literal: true

require 'json'
require 'sketchup'

module FurnitureDistributor
  PLUGIN_VERSION = "1.0.2"
  GITHUB_USER    = "byurii94"
  GITHUB_REPO    = "furniture_distributor"
  GITHUB_BRANCH  = "main"
  RAW_BASE_URL   = "https://raw.githubusercontent.com/#{GITHUB_USER}/#{GITHUB_REPO}/#{GITHUB_BRANCH}"

  @http_requests = []

  def self.parse_float(val)
    return val.to_f if val.is_a?(Numeric)
    val.to_s.tr(',', '.').to_f
  end

  def self.parse_int(val)
    return val.to_i if val.is_a?(Numeric)
    val.to_s.tr(',', '.').to_i
  end

  # Порівняння версій типу "1.0.10" > "1.0.3"
  def self.version_newer?(remote_ver, local_ver)
    r_parts = remote_ver.to_s.strip.split('.').map(&:to_i)
    l_parts = local_ver.to_s.strip.split('.').map(&:to_i)
    max_len = [r_parts.length, l_parts.length].max
    max_len.times do |i|
      rv = r_parts[i] || 0
      lv = l_parts[i] || 0
      return true  if rv > lv
      return false if rv < lv
    end
    false
  end

  def self.send_http_get(url, &callback)
    req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
    @http_requests << req

    req.start do |request, response|
      @http_requests.delete(req)
      callback.call(request, response)
    end
  end

  def self.check_for_updates(silent: true)
    url = "#{RAW_BASE_URL}/version.json?t=#{Time.now.to_i}"
    send_http_get(url) do |_request, response|
      if response.nil? || response.status_code != 200
        unless silent
          UI.messagebox("Не вдалося перевірити оновлення на GitHub (код: #{response ? response.status_code : 'немає з’єднання'}).")
        end
        next
      end

      begin
        data = JSON.parse(response.body.to_s)
      rescue => e
        UI.messagebox("Помилка читання version.json з GitHub: #{e.message}") unless silent
        next
      end

      remote_ver = data["version"].to_s.strip
      if remote_ver.empty? || !version_newer?(remote_ver, PLUGIN_VERSION)
        UI.messagebox("Встановлена актуальна версія плагіна (v#{PLUGIN_VERSION}).") unless silent
        next
      end

      notes = data["notes"].to_s.strip
      msg = "Доступна нова версія «Розкладки фурнітури»: v#{remote_ver} (поточна: v#{PLUGIN_VERSION})."
      msg += "\n\nЗміни:\n#{notes}" unless notes.empty?
      msg += "\n\nОновити плагін зараз?"

      if UI.messagebox(msg, MB_YESNO) == IDYES
        download_and_install_update(remote_ver)
      end
    end
  end

  def self.download_and_install_update(remote_ver)
    plugin_dir = File.dirname(__FILE__)
    cache_bust = "t=#{Time.now.to_i}"

    send_http_get("#{RAW_BASE_URL}/main.rb?#{cache_bust}") do |_request, response|
      if response.nil? || response.status_code != 200 || response.body.to_s.strip.empty?
        UI.messagebox("Не вдалося завантажити main.rb з GitHub.")
        next
      end

      begin
        main_path = File.join(plugin_dir, "main.rb")
        File.binwrite(main_path, response.body)

        # Опціонально оновлюємо іконки, якщо вони є в репозиторії
        %w[hinge_16.png hinge_24.png].each do |icon_name|
          send_http_get("#{RAW_BASE_URL}/images/#{icon_name}?#{cache_bust}") do |_ireq, ires|
            if ires && ires.status_code == 200 && !ires.body.to_s.empty?
              img_dir = File.join(plugin_dir, "images")
              Dir.mkdir(img_dir) unless Dir.exist?(img_dir)
              File.binwrite(File.join(img_dir, icon_name), ires.body)
            end
          end
        end

        UI.messagebox("Плагін оновлено до v#{remote_ver}! Перезапустіть SketchUp, щоб зміни застосувалися повністю.")
      rescue => e
        UI.messagebox("Помилка запису оновлення: #{e.message}")
      end
    end
  end

  class FurnitureEdgeTool
    def initialize(donors)
      @donors = donors.map do |ent|
        {
          entity: ent,
          tr: ent.transformation,
          center: Geom::Point3d.new(ent.bounds.center)
        }
      end

      @hover_edge = nil
      @hover_tr = Geom::Transformation.new
      @selected_edge = nil
      @edge_start = nil
      @edge_end = nil
      @edge_dir = nil
      @edge_length_mm = 0.0

      @dialog = nil
      @generated = false
      @raw_gaps = Array.new(3, "")
      @gaps_mm = []
      @positions_mm = []

      @params = {
        num_items: 2
      }
    end

    def activate
      @hover_edge = nil
      @selected_edge = nil
      @generated = false
      names = @donors.map { |d| d[:entity].name.to_s.empty? ? "Група" : d[:entity].name }.join(" + ")
      Sketchup.set_status_text(
        "🔩 РОЗКЛАДКА ФУРНІТУРИ ПО ЦЕНТРУ (#{names}) | Наведіть на ребро деталі та клікніть | ESC = Вихід"
      )
      Sketchup.active_model.active_view&.invalidate
    end

    def deactivate(view)
      close_dialog
      view.invalidate if view
    end

    def onCancel(_reason, view)
      close_dialog
      view.invalidate if view
    end

    def onKeyDown(key, _repeat, _flags, _view)
      if key == 27
        close_dialog
        Sketchup.active_model.select_tool(nil)
      end
    end

    def onMouseMove(_flags, x, y, view)
      return if @selected_edge

      edge, tr = pick_edge_at(view, x, y)
      if edge != @hover_edge || tr != @hover_tr
        @hover_edge = edge
        @hover_tr = tr || Geom::Transformation.new
        if @hover_edge && @hover_edge.valid?
          len_mm = (@hover_edge.start.position.transform(@hover_tr).distance(@hover_edge.end.position.transform(@hover_tr))).to_mm.to_f
          Sketchup.set_status_text(
            "🔩 Ребро (#{len_mm.round(1)} мм) — клікніть, щоб відкрити вікно проміжків | ESC = Вихід"
          )
        else
          Sketchup.set_status_text(
            "🔩 Наведіть курсор на ребро деталі, вздовж якого розкласти фурнітуру | ESC = Вихід"
          )
        end
        view.invalidate
      end
    end

    def onLButtonDown(_flags, x, y, view)
      return if @selected_edge

      edge, tr = pick_edge_at(view, x, y)
      return unless edge && edge.valid?

      world_tr = tr || Geom::Transformation.new
      p_a = Geom::Point3d.new(edge.start.position.transform(world_tr))
      p_b = Geom::Point3d.new(edge.end.position.transform(world_tr))

      if (p_b.z - p_a.z).abs > 1e-6 && p_b.z < p_a.z
        p_a, p_b = p_b, p_a
      end

      vec = p_b - p_a
      return if vec.length <= 1e-6

      @selected_edge = edge
      @edge_start = p_a
      @edge_end = p_b
      @edge_dir = vec.normalize
      @edge_length_mm = vec.length.to_mm.to_f

      n = @params[:num_items]
      @raw_gaps = Array.new(n + 1, "")
      recompute_layout!

      open_dialog
      view.invalidate
    end

    def draw(view)
      if @selected_edge.nil? && @hover_edge && @hover_edge.valid?
        pts = [
          @hover_edge.start.position.transform(@hover_tr),
          @hover_edge.end.position.transform(@hover_tr)
        ]
        view.drawing_color = Sketchup::Color.new(40, 185, 65)
        view.line_width = 8
        view.draw(GL_LINES, pts)
        return
      end

      return unless @selected_edge && @edge_start && @edge_dir

      view.drawing_color = Sketchup::Color.new(0, 120, 215)
      view.line_width = 4
      view.draw(GL_LINES, [@edge_start, @edge_end])

      return unless valid_layout?

      dash_len  = 18.0.mm
      gap_len   = 12.0.mm
      half_span = 220.0.mm

      horiz = @edge_dir * Geom::Vector3d.new(0, 1, 0)
      horiz = @edge_dir * Geom::Vector3d.new(1, 0, 0) if horiz.length < 1e-6
      horiz.normalize!

      @positions_mm.each do |pos_mm|
        pt = @edge_start.offset(@edge_dir, pos_mm.mm)

        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(245, 158, 11)
        [-1.0, 1.0].each do |dir_sign|
          cur = 0.0
          while cur < half_span
            s0 = pt.offset(horiz, dir_sign * cur)
            s1 = pt.offset(horiz, dir_sign * [cur + dash_len, half_span].min)
            view.draw(GL_LINES, [s0, s1])
            cur += dash_len + gap_len
          end
        end

        view.draw_points([pt], 10, 2, Sketchup::Color.new(220, 38, 38))
      end
    end

    private

    def pick_edge_at(view, x, y)
      ip = view.inputpoint(x, y)
      if ip.edge && ip.edge.valid?
        return [ip.edge, ip.transformation]
      end

      ph = view.pick_helper
      ph.do_pick(x, y)
      (0...ph.count).each do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Edge) && leaf.valid?
          return [leaf, ph.transformation_at(i)]
        end
      end

      [nil, Geom::Transformation.new]
    end

    def calculate_furniture_gaps(total_len_mm, num_items, raw_inputs)
      num_gaps = num_items + 1
      fixed_vals = Array.new(num_gaps, nil)
      auto_indices = []
      fixed_sum = 0.0

      num_gaps.times do |i|
        raw = raw_inputs ? raw_inputs[i] : nil
        if !raw.nil? && !raw.to_s.strip.empty?
          val = FurnitureDistributor.parse_float(raw)
          if val >= 0.0
            r = val.round(1)
            fixed_vals[i] = r
            fixed_sum = (fixed_sum + r).round(1)
          else
            auto_indices << i
          end
        else
          auto_indices << i
        end
      end

      if auto_indices.empty?
        return Array.new(num_gaps) { |i| (fixed_vals[i] || 0.0).round(1) }
      end

      remainder = total_len_mm - fixed_sum
      return Array.new(num_gaps) { |i| (fixed_vals[i] || 0.0).round(1) } if remainder < -0.01

      each_auto = ([remainder, 0.0].max / auto_indices.length.to_f).round(1)
      result = Array.new(num_gaps, 0.0)
      sum_before_last = 0.0
      last_auto_idx = auto_indices.last

      num_gaps.times do |i|
        if !fixed_vals[i].nil?
          result[i] = fixed_vals[i]
        elsif i != last_auto_idx
          result[i] = each_auto
        end
        sum_before_last = (sum_before_last + result[i]).round(1) if i != last_auto_idx
      end

      result[last_auto_idx] = [(total_len_mm - sum_before_last).round(1), 0.0].max
      result
    end

    def recompute_layout!
      n = @params[:num_items]
      @gaps_mm = calculate_furniture_gaps(@edge_length_mm, n, @raw_gaps)

      positions = []
      acc = 0.0
      n.times do |i|
        acc = (acc + (@gaps_mm[i] || 0.0)).round(1)
        positions << acc
      end
      @positions_mm = positions
    end

    def valid_layout?
      return false unless @selected_edge && @edge_start && @edge_dir
      n = @params[:num_items]
      return false if n <= 0
      return false unless @gaps_mm.is_a?(Array) && @gaps_mm.length == n + 1
      return false if @gaps_mm.any? { |g| g.nil? || g < 0 }
      @gaps_mm.sum <= @edge_length_mm + 0.05
    end

    def open_dialog
      close_dialog

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Розкладка фурнітури по ребру",
        preferences_key: "FurnitureDistributorDialog",
        scrollable: true,
        resizable: true,
        width: 440,
        height: 520,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.set_html(build_furniture_dialog_html)

      @dialog.add_action_callback("ready") do |_ctx|
        send_init_data
      end

      @dialog.add_action_callback("update_params") do |_ctx, json_str|
        apply_data_from_js(json_str)
        Sketchup.active_model.active_view&.invalidate
      end

      @dialog.add_action_callback("apply") do |_ctx, json_str|
        apply_data_from_js(json_str)
        if generate_furniture
          close_dialog
          Sketchup.active_model.select_tool(nil)
        end
      end

      @dialog.set_on_closed do
        @dialog = nil
        unless @generated
          Sketchup.active_model.select_tool(nil)
        end
      end

      @dialog.show
    end

    def apply_data_from_js(json_str)
      data = JSON.parse(json_str)
      n = [FurnitureDistributor.parse_int(data["num_items"]), 1].max
      @params[:num_items] = n

      @raw_gaps = Array.new(n + 1) { |i| data["raw_gaps"] ? data["raw_gaps"][i].to_s : "" }
      recompute_layout!
    end

    def send_init_data
      return unless @dialog
      donor_text = @donors.length == 2 ? "2 групи фурнітури" : "1 група фурнітури"
      payload = {
        axis_length: @edge_length_mm.round(1),
        donor_label: donor_text,
        num_items: @params[:num_items],
        gaps: @gaps_mm
      }
      @dialog.execute_script("initFurnitureDialog(#{payload.to_json});")
    end

    def close_dialog
      if @dialog
        dlg = @dialog
        @dialog = nil
        dlg.close
      end
    end

    def generate_furniture
      valid_donors = @donors.select { |d| d[:entity] && d[:entity].valid? }
      if valid_donors.empty? || !valid_layout?
        UI.messagebox("Перевірте обрані групи-донори та задані проміжки (чи не перевищують довжину ребра).")
        return false
      end

      model = Sketchup.active_model
      model.start_operation("Розкладка фурнітури (#{@params[:num_items]} шт.)", true)

      begin
        @positions_mm.each_with_index do |pos_mm, idx|
          target_base = @edge_start.offset(@edge_dir, pos_mm.mm)

          valid_donors.each do |d|
            ent = d[:entity]
            orig_center = Geom::Point3d.new(ent.bounds.center)

            d_vec = orig_center - @edge_start
            along_len = d_vec % @edge_dir
            along_vec = Geom::Vector3d.new(
              @edge_dir.x * along_len,
              @edge_dir.y * along_len,
              @edge_dir.z * along_len
            )
            perp_vec = Geom::Vector3d.new(
              d_vec.x - along_vec.x,
              d_vec.y - along_vec.y,
              d_vec.z - along_vec.z
            )

            target_center = target_base + perp_vec
            move_vec = Geom::Vector3d.new(
              target_center.x - orig_center.x,
              target_center.y - orig_center.y,
              target_center.z - orig_center.z
            )

            copy_ent = if ent.is_a?(Sketchup::Group)
                         ent.copy
                       elsif ent.is_a?(Sketchup::ComponentInstance)
                         ent.parent.entities.add_instance(ent.definition, ent.transformation)
                       end
            next unless copy_ent

            copy_ent.name = ent.name.to_s.empty? ? "Фурнітура #{idx + 1}" : ent.name
            copy_ent.material = ent.material if ent.material
            copy_ent.layer = ent.layer if ent.layer

            if move_vec.length > 1e-9
              copy_ent.transform!(Geom::Transformation.translation(move_vec))
            end
          end
        end

        valid_donors.each do |d|
          d[:entity].erase! if d[:entity] && d[:entity].valid?
        end

        model.commit_operation
        @generated = true
        true
      rescue => e
        model.abort_operation
        UI.messagebox("Помилка при створенні фурнітури: #{e.message}")
        false
      end
    end

    def build_furniture_dialog_html
      <<~HTML
        <!DOCTYPE html>
        <html lang="uk">
        <head>
          <meta charset="UTF-8">
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              font-size: 13px;
              margin: 12px;
              color: #1f2937;
              background: #f9fafb;
            }
            .card {
              background: #fff;
              border: 1px solid #e5e7eb;
              border-radius: 8px;
              padding: 10px 12px;
              margin-bottom: 10px;
            }
            .badge {
              display: inline-block;
              background: #eff6ff;
              color: #1d4ed8;
              border: 1px solid #bfdbfe;
              border-radius: 6px;
              padding: 4px 8px;
              font-weight: 600;
              margin-bottom: 6px;
            }
            .meta {
              font-size: 12px;
              color: #4b5563;
            }
            label {
              display: block;
              font-size: 11px;
              color: #374151;
              margin-bottom: 3px;
              font-weight: 600;
            }
            input[type="number"], input[type="text"] {
              width: 100%;
              box-sizing: border-box;
              padding: 6px 8px;
              border: 1px solid #d1d5db;
              border-radius: 6px;
              font-size: 13px;
            }
            .row-gap {
              display: grid;
              grid-template-columns: 98px 1fr 78px;
              align-items: center;
              gap: 6px;
              margin-bottom: 6px;
            }
            .row-label {
              font-size: 12px;
              font-weight: 600;
              white-space: nowrap;
            }
            .calc-val {
              font-size: 11px;
              color: #4b5563;
              text-align: right;
              white-space: nowrap;
            }
            .hint {
              font-size: 11px;
              color: #6b7280;
              margin-top: 4px;
            }
            .error-text {
              font-size: 11px;
              color: #dc2626;
              font-weight: 600;
              margin-top: 4px;
            }
            .hidden {
              display: none;
            }
            .btn-apply {
              width: 100%;
              padding: 9px 12px;
              background: #2563eb;
              color: #fff;
              border: none;
              border-radius: 8px;
              font-size: 14px;
              font-weight: 600;
              cursor: pointer;
            }
            .btn-apply:hover {
              background: #1d4ed8;
            }
          </style>
        </head>
        <body>
          <div class="card">
            <div class="badge" id="lenBadge">Довжина ребра: —</div>
            <div class="meta" id="donorMeta">Донор: —</div>
          </div>

          <div class="card">
            <label for="num_items">Кількість елементів фурнітури (шт.)</label>
            <input type="number" id="num_items" step="1" min="1" max="30" value="2">
          </div>

          <div class="card">
            <label>Проміжки вздовж ребра (мм — порожнє = авто, залишок після округлення до 0.1 в останній)</label>
            <div id="gapsContainer"></div>
            <div class="error-text hidden" id="gapError"></div>
            <div class="hint">Червоні точки та жовтий пунктир у 3D показують позиції центрів фурнітури.</div>
          </div>

          <button class="btn-apply" id="applyBtn">Створити фурнітуру</button>

          <script>
            let edgeLenMm = 0;
            let rawGaps = [];

            function round1(val) {
              return Math.round(val * 10) / 10;
            }

            function parseNum(str) {
              if (str === null || str === undefined) return NaN;
              const cleaned = String(str).trim().replace(',', '.');
              if (cleaned === '') return NaN;
              return parseFloat(cleaned);
            }

            function notifyRuby(action, payloadObj) {
              window.location = 'skp:' + action + '@' + encodeURIComponent(JSON.stringify(payloadObj));
            }

            function computeGapsPreview(totalLen, count, rawInputs) {
              const numGaps = count + 1;
              const fixedVals = new Array(numGaps).fill(null);
              const autoIndices = [];
              let fixedSum = 0;

              for (let i = 0; i < numGaps; i++) {
                const val = parseNum(rawInputs ? rawInputs[i] : '');
                if (!isNaN(val) && val >= 0) {
                  const r = round1(val);
                  fixedVals[i] = r;
                  fixedSum = round1(fixedSum + r);
                } else {
                  autoIndices.push(i);
                }
              }

              if (autoIndices.length === 0) {
                const allFixed = fixedVals.map((v) => v !== null ? v : 0);
                const sumAll = allFixed.reduce((a, b) => a + b, 0);
                if (sumAll > totalLen + 0.05) {
                  return {
                    gaps: allFixed,
                    error: 'Сума проміжків (' + round1(sumAll) + ' мм) перевищує довжину ребра (' + round1(totalLen) + ' мм).'
                  };
                }
                return { gaps: allFixed, error: '' };
              }

              const remainder = totalLen - fixedSum;
              if (remainder < -0.05) {
                const fallback = fixedVals.map((v) => v !== null ? v : 0);
                return {
                  gaps: fallback,
                  error: 'Сума фіксованих проміжків перевищує довжину ребра.'
                };
              }

              const eachAuto = round1(Math.max(0, remainder) / autoIndices.length);
              const result = new Array(numGaps).fill(0);
              let sumBeforeLast = 0;
              const lastAutoIdx = autoIndices[autoIndices.length - 1];

              for (let i = 0; i < numGaps; i++) {
                if (fixedVals[i] !== null) {
                  result[i] = fixedVals[i];
                } else if (i !== lastAutoIdx) {
                  result[i] = eachAuto;
                }
                if (i !== lastAutoIdx) {
                  sumBeforeLast = round1(sumBeforeLast + result[i]);
                }
              }

              result[lastAutoIdx] = round1(Math.max(0, totalLen - sumBeforeLast));
              return { gaps: result, error: '' };
            }

            function collectRawGapsFromDom(expectedGapsCount) {
              const inputs = document.querySelectorAll('.gap-input');
              const res = [];
              for (let i = 0; i < expectedGapsCount; i++) {
                res.push(inputs[i] ? inputs[i].value : (rawGaps[i] || ''));
              }
              return res;
            }

            function syncAndNotify() {
              const rawCount = parseInt(document.getElementById('num_items').value, 10);
              const count = Math.max(1, isNaN(rawCount) ? 1 : rawCount);

              rawGaps = collectRawGapsFromDom(count + 1);

              const calc = computeGapsPreview(edgeLenMm, count, rawGaps);
              const errEl = document.getElementById('gapError');
              if (calc.error) {
                errEl.textContent = calc.error;
                errEl.classList.remove('hidden');
              } else {
                errEl.textContent = '';
                errEl.classList.add('hidden');
              }

              const badges = document.querySelectorAll('.gap-calc-badge');
              for (let i = 0; i < count + 1; i++) {
                if (badges[i]) {
                  badges[i].textContent = calc.gaps[i] + ' мм';
                }
              }

              notifyRuby('update_params', {
                num_items: count,
                raw_gaps: rawGaps
              });
            }

            function renderGaps(count, rawArr, computedArr) {
              const container = document.getElementById('gapsContainer');
              container.innerHTML = '';
              for (let i = 0; i < count + 1; i++) {
                const row = document.createElement('div');
                row.className = 'row-gap';

                const lbl = document.createElement('span');
                lbl.className = 'row-label';
                lbl.textContent = 'Проміжок ' + (i + 1) + ':';

                const inp = document.createElement('input');
                inp.type = 'text';
                inp.placeholder = 'Авто';
                inp.className = 'gap-input';
                inp.value = (rawArr && rawArr[i] !== undefined) ? String(rawArr[i]) : '';
                inp.addEventListener('input', syncAndNotify);

                const badge = document.createElement('span');
                badge.className = 'calc-val gap-calc-badge';
                const shown = (computedArr && computedArr[i] !== undefined) ? computedArr[i] : 0;
                badge.textContent = shown + ' мм';

                row.appendChild(lbl);
                row.appendChild(inp);
                row.appendChild(badge);
                container.appendChild(row);
              }
            }

            function initFurnitureDialog(data) {
              edgeLenMm = parseFloat(data.axis_length) || 0;
              document.getElementById('lenBadge').textContent = 'Довжина ребра: ' + edgeLenMm + ' мм';
              document.getElementById('donorMeta').textContent = 'Донор: ' + (data.donor_label || '1 група фурнітури');

              const count = Math.max(1, parseInt(data.num_items, 10) || 2);
              document.getElementById('num_items').value = count;

              rawGaps = new Array(count + 1).fill('');

              const calc = computeGapsPreview(edgeLenMm, count, rawGaps);
              renderGaps(count, rawGaps, calc.gaps);
              syncAndNotify();
            }

            function handleCountChange(e) {
              const rawCount = parseInt(e.target.value, 10);
              const count = Math.max(1, isNaN(rawCount) ? 1 : rawCount);

              rawGaps = collectRawGapsFromDom(count + 1);

              const calc = computeGapsPreview(edgeLenMm, count, rawGaps);
              renderGaps(count, rawGaps, calc.gaps);
              syncAndNotify();
            }

            const numItemsEl = document.getElementById('num_items');
            numItemsEl.addEventListener('input', handleCountChange);
            numItemsEl.addEventListener('change', handleCountChange);

            document.getElementById('applyBtn').addEventListener('click', () => {
              const rawCount = parseInt(document.getElementById('num_items').value, 10);
              const count = Math.max(1, isNaN(rawCount) ? 1 : rawCount);
              rawGaps = collectRawGapsFromDom(count + 1);

              notifyRuby('apply', {
                num_items: count,
                raw_gaps: rawGaps
              });
            });

            document.addEventListener('DOMContentLoaded', () => {
              window.location = 'skp:ready@';
            });
          </script>
        </body>
        </html>
      HTML
    end
  end

  def self.run
    model = Sketchup.active_model
    donors = model.selection.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }.first(2)
    if donors.empty?
      UI.messagebox("Спочатку оберіть 1 або 2 групи фурнітури, а потім запустіть інструмент.")
      return
    end
    model.select_tool(FurnitureEdgeTool.new(donors))
  end

  unless file_loaded?(__FILE__)
    ext_menu = UI.menu("Extensions")
    ext_menu.add_item("Розкладка фурнітури по ребру") { run }
    ext_menu.add_item("Перевірити оновлення (Розкладка фурнітури)") { check_for_updates(silent: false) }

    path = File.dirname(__FILE__)
    furniture_cmd = UI::Command.new("Розкладка фурнітури по ребру") { run }
    furniture_cmd.tooltip = "Обрати 1–2 групи фурнітури та розкласти вздовж ребра з проміжками"
    h16 = File.join(path, "images", "hinge_16.png")
    h24 = File.join(path, "images", "hinge_24.png")
    furniture_cmd.small_icon = h16 if File.exist?(h16)
    furniture_cmd.large_icon = h24 if File.exist?(h24)

    toolbar = UI::Toolbar.new("Розкладка фурнітури")
    toolbar.add_item(furniture_cmd)
    toolbar.restore

    # Тиха перевірка при старті SketchUp
    UI.start_timer(30.0, false) { check_for_updates(silent: true) }

    file_loaded(__FILE__)
  end
end