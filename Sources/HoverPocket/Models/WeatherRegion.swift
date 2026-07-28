import Foundation

struct WeatherRegion: Hashable, Identifiable, Sendable {
    let id: String
    let japaneseName: String
    let englishName: String
    let representativeCityJapanese: String
    let representativeCityEnglish: String
    let latitude: Double
    let longitude: Double

    func name(language: AppLanguage) -> String {
        language == .japanese ? japaneseName : englishName
    }

    func representativeCity(language: AppLanguage) -> String {
        language == .japanese ? representativeCityJapanese : representativeCityEnglish
    }

    static let defaultRegion = allRegions.first(where: { $0.id == "13" })!

    static func region(id: String) -> WeatherRegion? {
        allRegions.first(where: { $0.id == id })
    }

    // id は都道府県コード（JIS X 0401）。座標は都道府県庁所在地付近を0.01度単位で保持する。
    static let allRegions: [WeatherRegion] = [
        .init(id: "01", japaneseName: "北海道", englishName: "Hokkaido", representativeCityJapanese: "札幌", representativeCityEnglish: "Sapporo", latitude: 43.06, longitude: 141.35),
        .init(id: "02", japaneseName: "青森県", englishName: "Aomori", representativeCityJapanese: "青森", representativeCityEnglish: "Aomori", latitude: 40.82, longitude: 140.74),
        .init(id: "03", japaneseName: "岩手県", englishName: "Iwate", representativeCityJapanese: "盛岡", representativeCityEnglish: "Morioka", latitude: 39.70, longitude: 141.15),
        .init(id: "04", japaneseName: "宮城県", englishName: "Miyagi", representativeCityJapanese: "仙台", representativeCityEnglish: "Sendai", latitude: 38.27, longitude: 140.87),
        .init(id: "05", japaneseName: "秋田県", englishName: "Akita", representativeCityJapanese: "秋田", representativeCityEnglish: "Akita", latitude: 39.72, longitude: 140.10),
        .init(id: "06", japaneseName: "山形県", englishName: "Yamagata", representativeCityJapanese: "山形", representativeCityEnglish: "Yamagata", latitude: 38.24, longitude: 140.36),
        .init(id: "07", japaneseName: "福島県", englishName: "Fukushima", representativeCityJapanese: "福島", representativeCityEnglish: "Fukushima", latitude: 37.75, longitude: 140.47),
        .init(id: "08", japaneseName: "茨城県", englishName: "Ibaraki", representativeCityJapanese: "水戸", representativeCityEnglish: "Mito", latitude: 36.34, longitude: 140.45),
        .init(id: "09", japaneseName: "栃木県", englishName: "Tochigi", representativeCityJapanese: "宇都宮", representativeCityEnglish: "Utsunomiya", latitude: 36.56, longitude: 139.88),
        .init(id: "10", japaneseName: "群馬県", englishName: "Gunma", representativeCityJapanese: "前橋", representativeCityEnglish: "Maebashi", latitude: 36.39, longitude: 139.06),
        .init(id: "11", japaneseName: "埼玉県", englishName: "Saitama", representativeCityJapanese: "さいたま", representativeCityEnglish: "Saitama", latitude: 35.86, longitude: 139.65),
        .init(id: "12", japaneseName: "千葉県", englishName: "Chiba", representativeCityJapanese: "千葉", representativeCityEnglish: "Chiba", latitude: 35.61, longitude: 140.12),
        .init(id: "13", japaneseName: "東京都", englishName: "Tokyo", representativeCityJapanese: "東京", representativeCityEnglish: "Tokyo", latitude: 35.68, longitude: 139.76),
        .init(id: "14", japaneseName: "神奈川県", englishName: "Kanagawa", representativeCityJapanese: "横浜", representativeCityEnglish: "Yokohama", latitude: 35.45, longitude: 139.64),
        .init(id: "15", japaneseName: "新潟県", englishName: "Niigata", representativeCityJapanese: "新潟", representativeCityEnglish: "Niigata", latitude: 37.90, longitude: 139.02),
        .init(id: "16", japaneseName: "富山県", englishName: "Toyama", representativeCityJapanese: "富山", representativeCityEnglish: "Toyama", latitude: 36.70, longitude: 137.21),
        .init(id: "17", japaneseName: "石川県", englishName: "Ishikawa", representativeCityJapanese: "金沢", representativeCityEnglish: "Kanazawa", latitude: 36.56, longitude: 136.66),
        .init(id: "18", japaneseName: "福井県", englishName: "Fukui", representativeCityJapanese: "福井", representativeCityEnglish: "Fukui", latitude: 36.06, longitude: 136.22),
        .init(id: "19", japaneseName: "山梨県", englishName: "Yamanashi", representativeCityJapanese: "甲府", representativeCityEnglish: "Kofu", latitude: 35.66, longitude: 138.57),
        .init(id: "20", japaneseName: "長野県", englishName: "Nagano", representativeCityJapanese: "長野", representativeCityEnglish: "Nagano", latitude: 36.65, longitude: 138.18),
        .init(id: "21", japaneseName: "岐阜県", englishName: "Gifu", representativeCityJapanese: "岐阜", representativeCityEnglish: "Gifu", latitude: 35.42, longitude: 136.76),
        .init(id: "22", japaneseName: "静岡県", englishName: "Shizuoka", representativeCityJapanese: "静岡", representativeCityEnglish: "Shizuoka", latitude: 34.98, longitude: 138.38),
        .init(id: "23", japaneseName: "愛知県", englishName: "Aichi", representativeCityJapanese: "名古屋", representativeCityEnglish: "Nagoya", latitude: 35.18, longitude: 136.91),
        .init(id: "24", japaneseName: "三重県", englishName: "Mie", representativeCityJapanese: "津", representativeCityEnglish: "Tsu", latitude: 34.73, longitude: 136.51),
        .init(id: "25", japaneseName: "滋賀県", englishName: "Shiga", representativeCityJapanese: "大津", representativeCityEnglish: "Otsu", latitude: 35.00, longitude: 135.87),
        .init(id: "26", japaneseName: "京都府", englishName: "Kyoto", representativeCityJapanese: "京都", representativeCityEnglish: "Kyoto", latitude: 35.01, longitude: 135.77),
        .init(id: "27", japaneseName: "大阪府", englishName: "Osaka", representativeCityJapanese: "大阪", representativeCityEnglish: "Osaka", latitude: 34.69, longitude: 135.50),
        .init(id: "28", japaneseName: "兵庫県", englishName: "Hyogo", representativeCityJapanese: "神戸", representativeCityEnglish: "Kobe", latitude: 34.69, longitude: 135.20),
        .init(id: "29", japaneseName: "奈良県", englishName: "Nara", representativeCityJapanese: "奈良", representativeCityEnglish: "Nara", latitude: 34.69, longitude: 135.83),
        .init(id: "30", japaneseName: "和歌山県", englishName: "Wakayama", representativeCityJapanese: "和歌山", representativeCityEnglish: "Wakayama", latitude: 34.23, longitude: 135.17),
        .init(id: "31", japaneseName: "鳥取県", englishName: "Tottori", representativeCityJapanese: "鳥取", representativeCityEnglish: "Tottori", latitude: 35.50, longitude: 134.24),
        .init(id: "32", japaneseName: "島根県", englishName: "Shimane", representativeCityJapanese: "松江", representativeCityEnglish: "Matsue", latitude: 35.47, longitude: 133.05),
        .init(id: "33", japaneseName: "岡山県", englishName: "Okayama", representativeCityJapanese: "岡山", representativeCityEnglish: "Okayama", latitude: 34.66, longitude: 133.93),
        .init(id: "34", japaneseName: "広島県", englishName: "Hiroshima", representativeCityJapanese: "広島", representativeCityEnglish: "Hiroshima", latitude: 34.40, longitude: 132.46),
        .init(id: "35", japaneseName: "山口県", englishName: "Yamaguchi", representativeCityJapanese: "山口", representativeCityEnglish: "Yamaguchi", latitude: 34.19, longitude: 131.47),
        .init(id: "36", japaneseName: "徳島県", englishName: "Tokushima", representativeCityJapanese: "徳島", representativeCityEnglish: "Tokushima", latitude: 34.07, longitude: 134.56),
        .init(id: "37", japaneseName: "香川県", englishName: "Kagawa", representativeCityJapanese: "高松", representativeCityEnglish: "Takamatsu", latitude: 34.34, longitude: 134.05),
        .init(id: "38", japaneseName: "愛媛県", englishName: "Ehime", representativeCityJapanese: "松山", representativeCityEnglish: "Matsuyama", latitude: 33.84, longitude: 132.77),
        .init(id: "39", japaneseName: "高知県", englishName: "Kochi", representativeCityJapanese: "高知", representativeCityEnglish: "Kochi", latitude: 33.56, longitude: 133.53),
        .init(id: "40", japaneseName: "福岡県", englishName: "Fukuoka", representativeCityJapanese: "福岡", representativeCityEnglish: "Fukuoka", latitude: 33.59, longitude: 130.40),
        .init(id: "41", japaneseName: "佐賀県", englishName: "Saga", representativeCityJapanese: "佐賀", representativeCityEnglish: "Saga", latitude: 33.25, longitude: 130.30),
        .init(id: "42", japaneseName: "長崎県", englishName: "Nagasaki", representativeCityJapanese: "長崎", representativeCityEnglish: "Nagasaki", latitude: 32.75, longitude: 129.87),
        .init(id: "43", japaneseName: "熊本県", englishName: "Kumamoto", representativeCityJapanese: "熊本", representativeCityEnglish: "Kumamoto", latitude: 32.79, longitude: 130.74),
        .init(id: "44", japaneseName: "大分県", englishName: "Oita", representativeCityJapanese: "大分", representativeCityEnglish: "Oita", latitude: 33.24, longitude: 131.61),
        .init(id: "45", japaneseName: "宮崎県", englishName: "Miyazaki", representativeCityJapanese: "宮崎", representativeCityEnglish: "Miyazaki", latitude: 31.91, longitude: 131.42),
        .init(id: "46", japaneseName: "鹿児島県", englishName: "Kagoshima", representativeCityJapanese: "鹿児島", representativeCityEnglish: "Kagoshima", latitude: 31.60, longitude: 130.56),
        .init(id: "47", japaneseName: "沖縄県", englishName: "Okinawa", representativeCityJapanese: "那覇", representativeCityEnglish: "Naha", latitude: 26.21, longitude: 127.68)
    ]
}
