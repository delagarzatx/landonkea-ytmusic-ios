// EqualizerView.swift, The Winamp-style equalizer window: preamp plus
// 31 vertical band sliders (ISO 1/3-octave, 20 Hz – 20 kHz), preset
// chips, and the user's own saved presets. Ronda 6 restyle: the logic
// (EqualizerManager) is unchanged in spirit, only the band count grew
// from 10 to 31 and the face went full Winamp.

import SwiftUI

/// LED green, matching the player face.
private let eqGreen = Color(red: 0.16, green: 0.96, blue: 0.26)
private let eqGreenDim = Color(red: 0.10, green: 0.55, blue: 0.16)
private let eqLCD = Color(red: 0.02, green: 0.05, blue: 0.02)

struct EqualizerView: View {

    @EnvironmentObject var equalizer: EqualizerManager
    @Environment(\.dismiss) var dismiss

    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    powerToggleSection
                    activePresetSection
                    bandsSection
                    presetsSection
                    Text("The equalizer processes downloaded songs (the local playback path). Streamed songs play through AVPlayer, which iOS does not let apps equalize.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(eqGreenDim)
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(eqGreen)
                }
            }
            .alert("Save Preset", isPresented: $showSavePresetAlert) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") {
                    equalizer.saveCustomPreset(name: newPresetName)
                    newPresetName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPresetName = ""
                }
            } message: {
                Text("Save the current band settings as a named preset you can reuse later.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    /// Master on/off switch, Winamp's EQ "ON" button as a toggle.
    private var powerToggleSection: some View {
        HStack {
            Text("WINAMP EQUALIZER")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundColor(eqGreen)

            Spacer()

            Toggle("", isOn: Binding(
                get: { equalizer.isEnabled },
                set: { _ in equalizer.toggle() }
            ))
            .labelsHidden()
            .tint(eqGreen)
        }
        .padding(.horizontal)
    }

    /// Which preset is active right now.
    private var activePresetSection: some View {
        HStack {
            Text("ACTIVE:")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(eqGreenDim)

            Text(equalizer.activePreset.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(eqGreen)

            Spacer()
        }
        .padding(.horizontal)
    }

    /// Preamp + the 31 band sliders in a horizontal scroll, like a real
    /// 31-band graphic EQ rack: grab and slide sideways to reach 20 kHz.
    private var bandsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PREAMP + 31 BANDS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(eqGreen)
                Spacer()
                Text("◀ SLIDE ▶")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(eqGreenDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    preampSlider
                    Rectangle()
                        .fill(eqGreenDim.opacity(0.5))
                        .frame(width: 1, height: 190)
                    ForEach(0..<EqualizerManager.bandFrequencies.count, id: \.self) { band in
                        bandSlider(band: band)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(eqLCD)
        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 8)
    }

    /// The Winamp preamp slider (overall gain, -12 to +12 dB).
    private var preampSlider: some View {
        VStack(spacing: 6) {
            Text("\(Int(equalizer.preamp))dB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(eqGreen)
                .frame(width: 36)

            WinampVSlider(value: Binding(
                get: { equalizer.preamp },
                set: { newValue in equalizer.setPreamp(newValue) }
            ))

            Text("PRE")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(eqGreen)
        }
    }

    /// One vertical band slider with its dB readout and frequency label.
    private func bandSlider(band: Int) -> some View {
        VStack(spacing: 6) {
            Text("\(Int(equalizer.bandGains[band]))dB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 36)

            WinampVSlider(value: Binding(
                get: { equalizer.bandGains[band] },
                set: { newValue in equalizer.setBand(band, gain: newValue) }
            ))

            Text(EqualizerManager.bandLabels[band])
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(eqGreenDim)
        }
    }

    /// Preset chips: built-ins, the transient "Custom", and the user's
    /// saved presets (long-press to delete), plus "Save Current".
    private var presetsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("PRESETS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(eqGreen)

                Spacer()

                Button {
                    showSavePresetAlert = true
                } label: {
                    Label("Save Current", systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(eqGreen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 10
            ) {
                if equalizer.activePreset == "Custom" {
                    PresetButton(name: "Custom", isActive: true, action: {})
                }

                ForEach(Array(EqualizerManager.presets.keys.sorted()), id: \.self) { name in
                    PresetButton(
                        name: name,
                        isActive: equalizer.activePreset == name,
                        action: { equalizer.applyPreset(name) }
                    )
                }

                ForEach(Array(equalizer.customPresets.keys.sorted()), id: \.self) { name in
                    PresetButton(
                        name: name,
                        isActive: equalizer.activePreset == name,
                        action: { equalizer.applyPreset(name) }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            equalizer.deleteCustomPreset(name: name)
                        } label: {
                            Label("Delete Preset", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Winamp vertical slider

/// A vertical -12…+12 dB fader with the classic EQ look: a thin colored
/// track (green at the bottom, red at the top) and a chunky metal thumb.
/// Dragging anywhere on the track moves the thumb to the finger.
struct WinampVSlider: View {
    @Binding var value: Double

    private let trackHeight: CGFloat = 150
    private let thumbHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            // Fraction 0 at -12 dB (bottom), 1 at +12 dB (top).
            let fraction = (value + 12) / 24
            let thumbY = (1 - fraction) * (geo.size.height - thumbHeight)

            ZStack(alignment: .top) {
                // Track
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.98, green: 0.25, blue: 0.15),
                                 Color(red: 0.98, green: 0.85, blue: 0.20),
                                 eqGreen],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: geo.size.height)
                    .frame(maxWidth: .infinity)

                // Center (0 dB) tick
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 14, height: 1)
                    .frame(maxWidth: .infinity)
                    .offset(y: geo.size.height / 2)

                // Thumb
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.25)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: thumbHeight)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .frame(maxWidth: .infinity)
                    .offset(y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = 1 - min(max(drag.location.y / geo.size.height, 0), 1)
                        value = -12 + f * 24
                    }
            )
        }
        .frame(width: 30, height: trackHeight)
    }
}

// MARK: - Preset Button

/// A single preset chip: black with a green border, filled green when
/// it is the active preset.
struct PresetButton: View {

    let name: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name.uppercased())
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? eqGreen : Color.black.opacity(0.55))
                .foregroundColor(isActive ? .black : eqGreen)
                .overlay(Rectangle().stroke(eqGreen.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EqualizerView()
        .environmentObject(EqualizerManager())
}
